// QueueItem.swift
//
// SwiftData-Model fuer einen einzelnen Upload-Job.
// Setzt PLAN.md Abschnitt 8 (Queue/Persistenz/Crash-Recovery) um:
// alle dort genannten Felder, inkl. der Idempotenz-Klammer
// (serverVideoId / serverVersionId).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// SwiftData verlangt iOS 17 / macOS 14 aufwaerts.

import Foundation
import SwiftData

@Model
final class QueueItem {

    // MARK: - Identitaet

    /// Stabile App-interne ID (auch fuer Datei-Namen im Scratch genutzt).
    @Attribute(.unique) var id: UUID

    /// Security-Scoped Bookmark der Quelldatei. Ueberlebt App-Neustart,
    /// damit der Zugriff nach Crash-Recovery wiederhergestellt werden kann.
    /// (PLAN.md Abschnitt 8: sourceBookmark)
    var sourceBookmark: Data?

    /// Anzeigename (Dateiname). Wird auch zum Dedup-Hint genutzt.
    var displayName: String

    /// Roher ffprobe-JSON-Output (zur Nachvollziehbarkeit / spaeteren Analyse).
    var probeJSON: String?

    // MARK: - Ziel und Encode

    /// cfStream / r2HLS / lokaler Export. Pro Item editierbar (vor Start).
    var targetRaw: String

    /// Gewuenschte Encode-Qualitaet pro Item (vor dem Encode editierbar).
    var qualityRaw: String = EncodeQuality.reviewFast.rawValue

    /// Wenn gesetzt: als neue Version dieses bestehenden Videos hochladen
    /// (kein neues Video anlegen). Steuert den Upload-Pfad.
    var newVersionOfVideoId: String?

    /// Eingefrorener Encode-Plan als JSON (EncodeSettings).
    var encodeSettingsJSON: String?

    /// Pfad des fertig encodierten Masters im Scratch (zum Upload und spaeteren Loeschen).
    var outputPath: String?

    // MARK: - Server-Zuordnung (UI + Idempotenz)

    /// Zielprojekt auf dem Server.
    var projectId: String?
    /// Zielordner innerhalb des Projekts.
    var folderId: String?

    /// Server-seitige Video-ID (aus POST /videos), wird wiederverwendet.
    var serverVideoId: String?

    /// Server-seitige Version-ID (aus r2-init/r2-stream). DIE Idempotenz-Klammer:
    /// ein Retry pollt nur noch cf-refresh auf diese ID, ruft nie erneut r2-stream.
    /// (PLAN.md Abschnitt 8)
    var serverVersionId: String?

    // MARK: - Laufzeit-Status

    /// Aktueller Status als Rohwert (ItemStatus).
    var statusRaw: String

    /// Fortschritt 0.0 bis 1.0 der aktuellen Phase.
    var progress: Double

    /// Bisherige automatische Retry-Versuche.
    var retryCount: Int

    /// Letzte Fehlermeldung (Klartext, ggf. stderr-Tail von ffmpeg).
    var lastError: String?

    // MARK: - Zeitstempel

    var createdAt: Date
    var updatedAt: Date

    /// Geprobte Dauer in Sekunden (Basis fuer -progress-Prozent). Optional bis Probe lief.
    var durationSeconds: Double?

    /// Quelldateigroesse in Bytes (fuer Upload-Pfad-Entscheidung und Disk-Check).
    var sourceSizeBytes: Int64?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        sourceBookmark: Data?,
        displayName: String,
        target: UploadTarget = .cfStream,
        projectId: String? = nil,
        folderId: String? = nil
    ) {
        self.id = id
        self.sourceBookmark = sourceBookmark
        self.displayName = displayName
        self.targetRaw = target.rawValue
        self.projectId = projectId
        self.folderId = folderId
        self.statusRaw = ItemStatus.queued.rawValue
        self.progress = 0
        self.retryCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Typ-sichere Wrapper

    /// Typ-sicherer Zugriff auf den Status (mit Fallback auf .queued).
    var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .queued }
        set {
            statusRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    /// Typ-sicherer Zugriff auf das Ziel.
    var target: UploadTarget {
        get { UploadTarget(rawValue: targetRaw) ?? .cfStream }
        set { targetRaw = newValue.rawValue }
    }

    /// Typ-sicherer Zugriff auf die gewuenschte Encode-Qualitaet.
    var quality: EncodeQuality {
        get { EncodeQuality(rawValue: qualityRaw) ?? .reviewFast }
        set { qualityRaw = newValue.rawValue }
    }

    /// Decodierter Encode-Plan-Snapshot, falls vorhanden.
    var encodeSettings: EncodeSettings? {
        get { EncodeSettings.decode(from: encodeSettingsJSON) }
        set { encodeSettingsJSON = newValue?.encodedJSON() }
    }

    // MARK: - Hilfen

    /// Setzt einen Fehlerzustand und merkt die Klartext-Meldung.
    func markFailed(_ message: String) {
        lastError = message
        status = .failed
    }

    /// Setzt den Fortschritt der aktuellen Phase und stempelt updatedAt.
    func setProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
        updatedAt = Date()
    }
}
