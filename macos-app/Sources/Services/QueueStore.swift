// QueueStore.swift
//
// @Observable Orchestrator + SwiftData-Persistenz. Zwei Stufen: Encode seriell,
// Upload 1-2 parallel, ueberlappend. Crash-Recovery beim Start (PLAN.md Abschnitt 8).
// Idempotenz ueber gemerkte serverVersionId. Setzt PLAN.md Abschnitt 8, 9, 11 um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Es werden hier keine echten Netzwerk-Calls ausgefuehrt.

import Foundation
import SwiftData
import Observation
import AppKit

@MainActor
@Observable
final class QueueStore {

    // MARK: - Abhaengigkeiten

    private let modelContext: ModelContext
    let tokenStore: TokenStore
    private let apiClient: ApiClient
    private let probeService: ProbeService
    private let encodeService: EncodeService
    private let uploadService: UploadService

    // MARK: - Sichtbarer Zustand

    /// Alle Items, sortiert nach Erstellzeit (neueste unten). Treibt die QueueListView.
    private(set) var items: [QueueItem] = []

    /// Globaler Banner-Zustand (z.B. "Token erneuern" bei 401).
    var tokenBannerVisible: Bool = false

    /// Transiente Statusmeldung fuer die UI (z.B. "Review-Link kopiert").
    var lastStatusMessage: String?

    /// Default-Zielprojekt/-ordner (zuletzt benutzt), fuer neue Drops.
    var defaultProjectID: String?
    var defaultFolderID: String?
    var defaultQuality: EncodeQuality = .reviewFast
    /// Ausgabe-Ziel fuer neue Drops: CF Stream, 4K-HLS oder lokaler Export.
    var defaultTarget: UploadTarget = .cfStream

    /// Angezeigter Pfad des gewaehlten Export-Ordners (lokale Konvertierung).
    /// Das eigentliche security-scoped Bookmark liegt in UserDefaults.
    var exportDirectoryPath: String?

    // MARK: - Standard-Optionen fuer neue Videos (Backend-Optionen)

    /// Downloads fuer neu angelegte Videos erlauben.
    var defaultDownloadsEnabled: Bool = true
    /// Download-Formate fuer neue Videos ("1080p" | "4k" | "original").
    var defaultDownloadFormats: [String] = ["1080p"]
    /// Versionen-Switcher fuer neue Videos (Kunde sieht alle Versionen).
    var defaultVersionSwitcher: Bool = false

    /// UserDefaults-Schluessel des Export-Ordner-Bookmarks.
    static let exportDirKey = "bdrop.exportDirBookmark"

    // MARK: - Interne Slot-Verwaltung

    /// Verhindert mehr als einen aktiven Encode (PLAN.md Abschnitt 8: ein Slot).
    private var encodeSlotBusy = false
    /// Zaehlt aktive Uploads gegen AppConfig.uploadConcurrency.
    private var activeUploads = 0

    /// Scratch-Ordner fuer encodierte Master (NICHT in ~/sync).
    private let scratchDir: URL

    // MARK: - Init

    init(
        modelContext: ModelContext,
        tokenStore: TokenStore,
        apiClient: ApiClient,
        uploadService: UploadService,
        probeService: ProbeService = ProbeService(),
        encodeService: EncodeService = EncodeService()
    ) {
        self.modelContext = modelContext
        self.tokenStore = tokenStore
        self.apiClient = apiClient
        self.uploadService = uploadService
        self.probeService = probeService
        self.encodeService = encodeService

        // Scratch unter ~/Library/Caches/<bundle>/scratch (vom Backup ausgeschlossen).
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.scratchDir = caches
            .appendingPathComponent("com.jonasbomba.bdropuploader", isDirectory: true)
            .appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        uploadService.delegate = self
        reload()
        exportDirectoryPath = resolveExportDirectory()?.path
    }

    // MARK: - Laden / Persistieren

    /// Liest alle Items aus SwiftData in den sichtbaren `items`-Array.
    func reload() {
        let descriptor = FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        items = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func save() {
        try? modelContext.save()
    }

    // MARK: - Drop -> neues Item (PLAN.md Abschnitt 11, Schritt 1)

    /// Erzeugt ein QueueItem aus einer gedroppten Datei-URL.
    /// Erwartet, dass der Aufrufer (DropZoneView) bereits ein Security-Scoped
    /// Bookmark erzeugt hat. Dedupliziert per Pfad/Name (PLAN.md Abschnitt 9).
    func enqueue(bookmark: Data, displayName: String, sourceSize: Int64?) {
        // Doppel-Drop-Schutz: gleicher Name, noch aktiv -> warnen, nicht doppelt.
        if items.contains(where: { $0.displayName == displayName && $0.status.isActive }) {
            return
        }
        let item = QueueItem(
            sourceBookmark: bookmark,
            displayName: displayName,
            target: defaultTarget,
            projectId: defaultProjectID,
            folderId: defaultFolderID)
        item.sourceSizeBytes = sourceSize
        modelContext.insert(item)
        save()
        reload()
        pumpPipeline()
    }

    // MARK: - Pipeline-Pump (Orchestrierung der zwei Stufen)

    /// Startet so viel Arbeit wie die Slots erlauben. Idempotent aufrufbar.
    func pumpPipeline() {
        guard !tokenBannerVisible else { return } // bei 401 alles pausieren

        // 1) Encode-Slot: ein wartendes Item probing/encoding starten.
        if !encodeSlotBusy,
           let next = items.first(where: { $0.status == .queued }) {
            encodeSlotBusy = true
            Task { await self.runProbeAndEncode(next) }
        }

        // 2) Upload-Slots: encodierte Items hochladen (1-2 parallel).
        while activeUploads < AppConfig.uploadConcurrency,
              let next = items.first(where: { $0.status == .encoded && $0.target == .cfStream }) {
            activeUploads += 1
            // Status sofort umsetzen, damit dieselbe Schleife es nicht erneut greift.
            next.status = .uploading
            save()
            Task { await self.runUpload(next) }
        }
    }

    // MARK: - Stufe 1: Probe + Encode (seriell)

    private func runProbeAndEncode(_ item: QueueItem) async {
        defer {
            encodeSlotBusy = false
            pumpPipeline()
        }

        guard let url = resolveBookmark(for: item) else {
            item.markFailed("Quelle nicht mehr auffindbar (Datei verschoben oder gelöscht).")
            save(); reload(); return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Disk-Check vor dem Encode (PLAN.md Abschnitt 9).
        if let free = Self.freeDiskBytes(), free < AppConfig.minFreeDiskBytes {
            item.markFailed("Zu wenig freier Speicher (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))). Bitte aufräumen.")
            save(); reload(); return
        }

        // --- Probe ---
        item.status = .probing
        save(); reload()

        let probe: ProbeResult
        do {
            probe = try probeService.probe(url: url)
        } catch {
            item.markFailed(error.localizedDescription)
            save(); reload(); return
        }

        if case .reject(let reason) = probe.classification {
            item.markFailed(reason)
            save(); reload(); return
        }

        item.probeJSON = probe.rawJSON
        item.durationSeconds = probe.durationSeconds

        // 6-Stunden-Cap pruefen (PLAN.md Abschnitt 4).
        if probe.durationSeconds > Double(AppConfig.maxDurationSecondsCap) {
            item.markFailed("Film länger als 6 Stunden - der Server lehnt das aktuell ab.")
            save(); reload(); return
        }

        // item (SwiftData @Model) ist nicht Sendable und darf nicht in die
        // @Sendable onProgress-Closure gefangen werden. Stattdessen die Sendable
        // UUID fangen und das Item auf dem MainActor ueber die items-Liste finden.
        let progressItemID = item.id
        let quality = item.encodeSettings?.quality ?? defaultQuality
        let onProgress: @Sendable (Double) -> Void = { [weak self] pct in
            Task { @MainActor in
                self?.items.first(where: { $0.id == progressItemID })?.setProgress(pct)
            }
        }

        // === HLS-Leiter (Ziel B: r2HLS oder lokaler HLS-Export). Immer Neu-Encode. ===
        if item.target.producesHLS {
            let settings = EncodeSettings(
                plan: .hlsLadder, quality: quality, sourceWasCompatible: false, videoTag: "avc1")
            item.encodeSettings = settings
            item.status = .encoding
            item.setProgress(0)
            save(); reload()
            do {
                let outDir = try await encodeService.encodeHLS(
                    input: url,
                    scratchDir: scratchDir,
                    itemID: item.id,
                    durationSeconds: probe.durationSeconds,
                    sourceWidth: probe.width,
                    hasAudio: probe.hasAudio,
                    maxWidth: quality.hlsMaxWidth,
                    onProgress: onProgress)
                item.outputPath = outDir.path
                if item.target.isLocal {
                    finishLocalExport(item, from: outDir, isDirectory: true)
                } else {
                    // r2HLS: geparkt bei .encoded (R2-Upload folgt).
                    item.status = .encoded
                    item.setProgress(1)
                }
                save(); reload()
            } catch EncodeError.cancelled {
                item.status = .queued; item.setProgress(0); save(); reload()
            } catch {
                item.markFailed(error.localizedDescription); save(); reload()
            }
            return
        }

        // === H.264-Master (cfStream-Upload oder lokaler H.264-Export) ===
        let settings = EncodeService.plan(for: probe, quality: quality)
        item.encodeSettings = settings
        item.status = .encoding
        item.setProgress(0)
        save(); reload()

        do {
            let result = try await encodeService.encode(
                input: url,
                scratchDir: scratchDir,
                itemID: item.id,
                durationSeconds: probe.durationSeconds,
                settings: settings,
                onProgress: onProgress)
            item.outputPath = result.outputURL.path
            item.encodeSettings = result.appliedSettings  // ggf. VideoToolbox-Fallback
            if item.target.isLocal {
                finishLocalExport(item, from: result.outputURL, isDirectory: false)
            } else {
                item.status = .encoded
                item.setProgress(1)
            }
            save(); reload()
        } catch EncodeError.cancelled {
            item.status = .queued
            item.setProgress(0)
            save(); reload()
        } catch {
            item.markFailed(error.localizedDescription)
            save(); reload()
        }
    }

    // MARK: - Lokaler Export (Konvertierung ohne Upload)

    /// Verschiebt das encodierte Ergebnis in den gewaehlten Export-Ordner und
    /// markiert das Item als fertig. Bei fehlendem Ordner -> Fehler mit Hinweis.
    private func finishLocalExport(_ item: QueueItem, from source: URL, isDirectory: Bool) {
        guard let dest = resolveExportDirectory() else {
            item.markFailed("Kein Export-Ordner gewählt. Bitte in den Einstellungen festlegen.")
            return
        }
        let accessing = dest.startAccessingSecurityScopedResource()
        defer { if accessing { dest.stopAccessingSecurityScopedResource() } }

        let base = (item.displayName as NSString).deletingPathExtension
        let targetName = isDirectory ? "\(base)-hls" : "\(base).mp4"
        let target = dest.appendingPathComponent(targetName, isDirectory: isDirectory)
        do {
            try? FileManager.default.removeItem(at: target)
            // Move ist auf gleichem Volume nahezu sofort; sonst faellt es auf Copy zurueck.
            do {
                try FileManager.default.moveItem(at: source, to: target)
            } catch {
                try FileManager.default.copyItem(at: source, to: target)
            }
            item.outputPath = target.path
            item.status = .done
            item.setProgress(1)
        } catch {
            item.markFailed("Export fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Loest den gespeicherten Export-Ordner (security-scoped Bookmark) auf.
    private func resolveExportDirectory() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.exportDirKey) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
    }

    /// Setzt den Export-Ordner aus einer vom Nutzer gewaehlten URL (Settings).
    func setExportDirectory(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.exportDirKey)
            exportDirectoryPath = url.path
        }
    }

    // MARK: - Stufe 2: Upload + Verify (1-2 parallel)

    private func runUpload(_ item: QueueItem) async {
        guard let outputPath = item.outputPath else {
            item.markFailed("Kein encodierter Master gefunden.")
            finishUploadSlot(); save(); reload(); return
        }
        let fileURL = URL(fileURLWithPath: outputPath)

        do {
            // Video anlegen, falls noch nicht geschehen (Idempotenz ueber serverVideoId).
            let videoID: String
            if let existing = item.serverVideoId {
                videoID = existing
            } else {
                videoID = try await apiClient.createVideo(
                    name: item.displayName,
                    projectID: item.projectId,
                    folderID: item.folderId)
                item.serverVideoId = videoID
                save()
                // Backend-Optionen fuer das neue Video setzen (best effort, blockiert
                // den Upload nicht). Bei bestehendem Video (neue Version) NICHT anfassen.
                _ = try? await apiClient.updateVideo(
                    videoID: videoID,
                    downloadsEnabled: defaultDownloadsEnabled,
                    downloadFormats: defaultDownloadsEnabled ? defaultDownloadFormats : nil,
                    versionSwitcherEnabled: defaultVersionSwitcher)
            }

            // Idempotenz: wenn schon eine version_id existiert, NICHT erneut hochladen,
            // sondern direkt cf-refresh pollen (PLAN.md Abschnitt 8).
            if let versionID = item.serverVersionId {
                try await verify(item: item, versionID: versionID)
                finishUploadSlot(); reload(); return
            }

            // r2-stream-Upload starten (Background-Session). Die version_id kommt
            // im didFinish-Callback zurueck, der die Verify-Phase ausloest.
            item.status = .uploading
            item.setProgress(0)
            save(); reload()

            let contentType = "video/mp4"
            let maxDuration = Int((item.durationSeconds ?? 0).rounded(.up))
            try uploadService.startStreamUpload(
                itemID: item.id,
                videoID: videoID,
                fileURL: fileURL,
                filename: item.displayName,
                contentType: contentType,
                maxDurationSeconds: maxDuration)
            // Slot bleibt belegt bis didComplete; Freigabe erfolgt in den Delegate-Pfaden.
        } catch let error as ApiError where error == .unauthorized {
            handleUnauthorized()
            // Item zurueck auf encoded, damit es nach Token-Eingabe weiterlaeuft.
            item.status = .encoded
            finishUploadSlot(); save(); reload()
        } catch {
            handleUploadError(item: item, error: error)
            finishUploadSlot()
        }
    }

    /// cf-refresh-Polling nach erfolgreichem Transfer (PLAN.md Abschnitt 11, Schritt 5).
    private func verify(item: QueueItem, versionID: String) async throws {
        item.status = .serverProcessing
        save(); reload()
        let ready = try await uploadService.pollCFRefresh(versionID: versionID)
        if ready {
            item.status = .done
            item.setProgress(1)
            // Scratch-Master loeschen (PLAN.md Abschnitt 11: ausser 4K-Download gewuenscht).
            if let path = item.outputPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        } else {
            item.markFailed("Cloudflare meldet einen Verarbeitungsfehler. Retry legt eine neue Version an.")
        }
        save(); reload()
    }

    // MARK: - Slot-Freigabe

    private func finishUploadSlot() {
        if activeUploads > 0 { activeUploads -= 1 }
        pumpPipeline()
    }

    // MARK: - Nutzer-Aktionen (Retry / Pause / Remove)

    /// Setzt ein fehlgeschlagenes/pausiertes Item zurueck in die Pipeline.
    /// Respektiert die Idempotenz-Klammer: existiert eine version_id, geht es
    /// direkt in die Verify-Phase statt neu hochzuladen.
    func retry(_ item: QueueItem) {
        guard item.status.isRetryable else { return }
        item.lastError = nil
        item.retryCount += 1
        if item.serverVersionId != nil {
            item.status = .encoded // -> Upload-Stufe erkennt version_id und pollt nur
        } else if item.outputPath != nil, FileManager.default.fileExists(atPath: item.outputPath!) {
            item.status = .encoded
        } else {
            item.status = .queued
        }
        save(); reload()
        pumpPipeline()
    }

    /// Pausiert ein Item (harter Stop, geht beim Resume neu durch die Stufe).
    func pause(_ item: QueueItem) {
        item.status = .paused
        save(); reload()
    }

    /// Entfernt ein Item samt Scratch-Output.
    func remove(_ item: QueueItem) {
        if let path = item.outputPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        modelContext.delete(item)
        save(); reload()
    }

    /// Zeigt die Ausgabe (Datei oder HLS-Ordner) im Finder.
    func revealInFinder(_ item: QueueItem) {
        guard let path = item.outputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Legt einen Review-Link zum fertigen Video an und kopiert ihn in die Zwischenablage.
    func createAndCopyReviewLink(_ item: QueueItem) async {
        guard let videoID = item.serverVideoId else {
            lastStatusMessage = "Kein Server-Video vorhanden - bitte erst hochladen."
            return
        }
        do {
            let link = try await apiClient.createVideoLink(videoID: videoID, options: LinkOptions())
            let url = Self.reviewURL(from: link)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url, forType: .string)
            lastStatusMessage = "Review-Link kopiert: \(url)"
        } catch {
            lastStatusMessage = "Review-Link fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Baut die Review-URL aus der Server-Antwort (bevorzugt url, sonst /review/<token>).
    private static func reviewURL(from link: LinkOut) -> String {
        if let u = link.url, !u.isEmpty { return u }
        return "https://jonasbomba.com/review/\(link.token ?? "")"
    }

    // MARK: - Token / Fehler (PLAN.md Abschnitt 9)

    private func handleUnauthorized() {
        // 401: alle Slots pausieren, Banner zeigen. NICHT bei 429.
        tokenBannerVisible = true
    }

    /// Nach Token-Eingabe: Banner weg, Pipeline weiterlaufen lassen.
    func clearTokenBannerAndResume() {
        tokenBannerVisible = false
        // Items in uploading ohne aktiven Task zurueck auf encoded.
        for item in items where item.status == .uploading {
            item.status = .encoded
        }
        save(); reload()
        pumpPipeline()
    }

    private func handleUploadError(item: QueueItem, error: Error) {
        if let api = error as? ApiError {
            switch api {
            case .unauthorized:
                handleUnauthorized()
                item.status = .encoded
            case .rateLimited, .serviceUnavailable, .transport:
                // Transient: zurueck auf encoded fuer automatischen Re-Pump.
                if item.retryCount < AppConfig.maxRetries {
                    item.retryCount += 1
                    item.status = .encoded
                } else {
                    item.markFailed(api.localizedDescription)
                }
            default:
                item.markFailed(api.localizedDescription)
            }
        } else {
            item.markFailed(error.localizedDescription)
        }
        save(); reload()
    }

    // MARK: - Crash-Recovery beim Start (PLAN.md Abschnitt 8)

    /// Muss einmal beim App-Start gerufen werden (nach Init).
    func performCrashRecovery() async {
        reload()

        // 1) Background-URLSession re-attachen: welche Item-IDs haben noch Tasks?
        let attachedIDs = Set(await uploadService.reattachTasks())

        for item in items {
            switch item.status {
            case .encoding, .probing:
                // 2) Encoding ohne lebenden Prozess -> zurueck auf queued, Teil-Output weg.
                if let path = item.outputPath {
                    try? FileManager.default.removeItem(atPath: path)
                    item.outputPath = nil
                }
                item.status = .queued
                item.setProgress(0)

            case .uploading:
                // 3) Upload mit version_id -> erst cf-refresh pollen.
                if let versionID = item.serverVersionId {
                    // In der Verify-Phase weiter, das Polling erledigt den Rest.
                    Task { @MainActor in
                        do { try await self.verify(item: item, versionID: versionID) }
                        catch { self.handleUploadError(item: item, error: error) }
                    }
                } else if attachedIDs.contains(item.id) {
                    // Transfer laeuft noch im Daemon -> nichts tun, Delegate uebernimmt.
                    break
                } else {
                    // Kein Task, keine version_id -> neu hochladen.
                    item.status = .encoded
                }

            case .serverProcessing:
                // Polling neu anstossen.
                if let versionID = item.serverVersionId {
                    Task { @MainActor in
                        do { try await self.verify(item: item, versionID: versionID) }
                        catch { self.handleUploadError(item: item, error: error) }
                    }
                }

            default:
                break
            }
        }
        save(); reload()
        pumpPipeline()
    }

    // MARK: - Bookmark-Aufloesung

    /// Loest ein Security-Scoped Bookmark auf und startet den Zugriff.
    /// Der Aufrufer MUSS stopAccessingSecurityScopedResource() aufrufen.
    private func resolveBookmark(for item: QueueItem) -> URL? {
        guard let data = item.sourceBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale) else {
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    // MARK: - Disk

    private static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - UploadServiceDelegate

extension QueueStore: UploadServiceDelegate {

    nonisolated func upload(itemID: UUID, didUpdateProgress progress: Double) {
        Task { @MainActor in
            if let item = self.items.first(where: { $0.id == itemID }) {
                item.setProgress(progress)
            }
        }
    }

    nonisolated func upload(itemID: UUID, didFinishWithResponseBody body: Data, httpStatus: Int) {
        Task { @MainActor in
            guard let item = self.items.first(where: { $0.id == itemID }) else { return }
            do {
                let versionID = try self.apiClient.parseVersionID(from: body)
                item.serverVersionId = versionID  // Idempotenz-Klammer sofort sichern
                self.save()
                try await self.verify(item: item, versionID: versionID)
            } catch {
                self.handleUploadError(item: item, error: error)
            }
            self.finishUploadSlot()
        }
    }

    nonisolated func upload(itemID: UUID, didFailWith error: Error) {
        Task { @MainActor in
            guard let item = self.items.first(where: { $0.id == itemID }) else { return }
            self.handleUploadError(item: item, error: error)
            self.finishUploadSlot()
        }
    }
}
