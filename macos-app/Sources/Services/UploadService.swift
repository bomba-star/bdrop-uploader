// UploadService.swift
//
// r2-stream als Default ueber URLSession.background(withIdentifier:) mit
// datei-basiertem uploadTask(with:fromFile:). Delegate liefert Per-Item-Progress
// (didSendBodyData). Nach Transfer-Abschluss cf-refresh-Polling mit Backoff.
// presigned-Multipart (Dateien ueber dem r2-stream-Cap) laeuft NICHT hier,
// sondern im MultipartUploader (Vordergrund-Session), orchestriert vom
// QueueStore (runMultipartUpload).
// Setzt PLAN.md Abschnitt 7 (Upload-Flows) und Abschnitt 10 (UploadService) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Es werden hier keine echten Netzwerk-Calls ausgefuehrt.

import Foundation

/// Callbacks, ueber die der UploadService den QueueStore informiert. Bewusst
/// schlank gehalten und @MainActor-frei (der QueueStore springt selbst auf Main).
protocol UploadServiceDelegate: AnyObject, Sendable {
    /// Fortschritt eines laufenden Uploads (0.0..1.0), zugeordnet ueber die App-Item-ID.
    func upload(itemID: UUID, didUpdateProgress progress: Double)
    /// Transfer fertig: der rohe Antwort-Body steht bereit (enthaelt version_id).
    func upload(itemID: UUID, didFinishWithResponseBody body: Data, httpStatus: Int)
    /// Transfer fehlgeschlagen (Transport-Ebene).
    func upload(itemID: UUID, didFailWith error: Error)
}

/// Verwaltet die Background-URLSession und das nachgelagerte cf-refresh-Polling.
final class UploadService: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let apiClient: ApiClient
    weak var delegate: UploadServiceDelegate?

    /// Background-Session. Ein einziger, stabiler Identifier -> Re-Attach nach Neustart.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: AppConfig.backgroundSessionID)
        config.isDiscretionary = false          // sofort starten, nicht auf "guenstige" Bedingungen warten
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = AppConfig.uploadConcurrency
        config.timeoutIntervalForRequest = AppConfig.uploadRequestTimeout // Netz-Haenger ueberleben (H5)
        config.timeoutIntervalForResource = 60 * 60 * 12 // 12h: grosse Filme + Hintergrund
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Mappt einen laufenden URLSessionTask auf die App-Item-ID (taskDescription).
    /// taskDescription ueberlebt App-Neustarts und Re-Attach.
    private let mapLock = NSLock()
    /// Sammelt pro Task die empfangenen Antwort-Bytes (r2-stream-Antwort ist klein).
    private var responseBuffers: [Int: Data] = [:]
    /// Item-IDs, fuer die seit App-Start bereits Delegate-Ereignisse (Progress
    /// oder Abschluss) eingetroffen sind (mapLock-geschuetzt). Grundlage fuer die
    /// Crash-Recovery: ein im Daemon fertig gewordener Task kann zum Zeitpunkt
    /// der allTasks-Abfrage schon aus der Session verschwunden sein, obwohl sein
    /// Abschluss noch auf dem MainActor zur Verarbeitung wartet - solche Items
    /// duerfen nicht als "verloren" neu hochgeladen werden (Fix H4).
    private var seenItemIDs: Set<UUID> = []

    /// Merkt, dass fuer diese Item-ID ein Delegate-Ereignis eingetroffen ist (Fix H4).
    private func markSeen(_ id: UUID) {
        mapLock.lock()
        seenItemIDs.insert(id)
        mapLock.unlock()
    }

    /// Synchroner Snapshot der gesehenen Item-IDs. Eigene sync-Funktion, weil
    /// Swift 6 lock()/unlock() direkt in async-Kontexten verbietet.
    private func seenSnapshot() -> Set<UUID> {
        mapLock.lock()
        defer { mapLock.unlock() }
        return seenItemIDs
    }

    /// Completion-Handler, den AppKit beim Background-Wake uebergibt (Re-Attach).
    var backgroundCompletionHandler: (() -> Void)?

    init(apiClient: ApiClient) {
        self.apiClient = apiClient
        super.init()
        // Lazy session bewusst beim Init anstossen, damit der Delegate sofort
        // laufende Hintergrund-Tasks aus einer vorherigen App-Sitzung einsammelt.
        _ = session
    }

    // MARK: - r2-stream Upload starten (Default-Pfad)

    /// Startet den r2-stream-Upload als datei-basierten Background-Task.
    /// - Parameters:
    ///   - itemID: App-interne Item-ID (wird als taskDescription gemerkt).
    ///   - videoID: serverseitige Video-ID (vorher via createVideo besorgt).
    ///   - fileURL: lokaler Pfad des encodierten Masters im Scratch.
    func startStreamUpload(
        itemID: UUID,
        videoID: String,
        fileURL: URL,
        filename: String,
        contentType: String,
        maxDurationSeconds: Int
    ) throws {
        let request = try apiClient.r2StreamRequest(
            videoID: videoID,
            filename: filename,
            contentType: contentType,
            maxDurationSeconds: maxDurationSeconds)

        // Datei-basierter Upload: ueberlebt App-Schliessen, kein Riesen-Body im RAM.
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = itemID.uuidString
        task.resume()
    }

    // MARK: - Re-Attach (Crash-Recovery, PLAN.md Abschnitt 8)

    /// Sammelt alle Tasks der Background-Session ein (laufend + abgeschlossen),
    /// damit der QueueStore Items zuordnen kann. Wird beim App-Start gerufen.
    /// Liefert zusaetzlich alle Items, fuer die bereits Delegate-Ereignisse
    /// eingetroffen sind: ein fertig gewordener Task faellt aus allTasks heraus,
    /// sobald seine Events zugestellt wurden - sein Item wird aber vom
    /// Delegate-Pfad weiterbehandelt und darf in der Crash-Recovery nicht auf
    /// .encoded zurueckfallen (Duplikat-Version, Fix H4).
    func reattachTasks() async -> [UUID] {
        let tasks = await session.allTasks
        var ids = seenSnapshot()
        for task in tasks {
            if let desc = task.taskDescription, let id = UUID(uuidString: desc) {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    /// Bricht einen laufenden Background-Upload-Task fuer das gegebene Item ab.
    func cancelTask(itemID: UUID) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == itemID.uuidString {
                task.cancel()
            }
        }
    }

    // MARK: - cf-refresh-Polling mit Backoff (PLAN.md Abschnitt 7, Schritt 3)

    /// Pollt cf-refresh mit Exponential-Backoff bis ready_to_stream, error oder Timeout.
    /// - Returns: true bei ready_to_stream, false bei Server-Error.
    func pollCFRefresh(versionID: String) async throws -> Bool {
        var delay = AppConfig.cfRefreshInitialDelay
        let deadline = Date().addingTimeInterval(AppConfig.cfRefreshTimeout)

        while Date() < deadline {
            do {
                let resp = try await apiClient.cfRefresh(versionID: versionID)
                switch resp.phase {
                case .ready:
                    return true
                case .error:
                    return false
                case .processing:
                    break
                }
            } catch let error as ApiError where error.isTransient {
                // 429/503/transport -> einfach weiter mit Backoff.
                _ = error
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * AppConfig.cfRefreshBackoffFactor, AppConfig.cfRefreshMaxDelay)
        }
        throw ApiError.transport("cf-refresh Timeout nach \(Int(AppConfig.cfRefreshTimeout))s.")
    }

    // MARK: - URLSessionTaskDelegate / DataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0,
              let desc = task.taskDescription, let id = UUID(uuidString: desc) else { return }
        markSeen(id) // Fix H4
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        delegate?.upload(itemID: id, didUpdateProgress: progress)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        mapLock.lock()
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
        mapLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription, let id = UUID(uuidString: desc) else { return }
        // Vor der Weitergabe markieren (Fix H4): laeuft die Crash-Recovery
        // parallel, sieht sie dieses Item als "Event unterwegs" statt "verloren".
        markSeen(id)

        mapLock.lock()
        let body = responseBuffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        mapLock.unlock()

        if let error {
            delegate?.upload(itemID: id, didFailWith: error)
            return
        }
        let http = task.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // 401/429/503 als Fehler weiterreichen, alles 2xx als Erfolg.
        if (200..<300).contains(status) {
            delegate?.upload(itemID: id, didFinishWithResponseBody: body, httpStatus: status)
        } else {
            let apiErr: Error
            switch status {
            case 401: apiErr = ApiError.unauthorized
            case 429:
                // Echten Retry-After-Wert durchreichen statt hart nil;
                // value(forHTTPHeaderField:) liest case-insensitiv (Fix K6).
                let retryAfterHeader = http?.value(forHTTPHeaderField: "Retry-After")
                apiErr = ApiError.rateLimited(retryAfter: retryAfterHeader.flatMap(TimeInterval.init))
            case 503: apiErr = ApiError.serviceUnavailable
            default:
                let text = String(data: body, encoding: .utf8) ?? ""
                apiErr = ApiError.httpError(status: status, body: String(text.prefix(300)))
            }
            delegate?.upload(itemID: id, didFailWith: apiErr)
        }
    }

    /// Wird gerufen, wenn alle Hintergrund-Events nach einem Wake abgearbeitet sind.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }

    // Hinweis: presigned Multipart (Dateien ueber dem r2-stream-Cap) liegt
    // bewusst NICHT in diesem Service - siehe Services/MultipartUploader.swift
    // (Part-PUTs) und QueueStore.runMultipartUpload (Orchestrierung).
}
