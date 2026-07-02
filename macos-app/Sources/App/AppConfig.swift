// AppConfig.swift
//
// Zentrale Konstanten und Limits der B-Drop Uploader App.
// Setzt PLAN.md Abschnitt 4 (Server-Endpoints/Limits) und Abschnitt 5 (Encode) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

/// Globale, prozessweite Konfiguration. Reine Werte, keine veraenderlichen Zustaende.
enum AppConfig {

    // MARK: - Server

    /// Basis-URL der CineReview/B-Drop Admin-API (verifiziert in PLAN.md Abschnitt 4).
    static let baseURL = URL(string: "https://jonasbomba.com")!

    /// Praefix aller Admin-Routen.
    static let adminPath = "/api/admin"

    // MARK: - Background-Upload

    /// Identifier der Background-URLSession. Muss stabil bleiben, damit ein
    /// laufender Transfer nach App-Neustart re-attached werden kann.
    static let backgroundSessionID = "com.jonasbomba.bdropuploader.upload"

    /// Request-Timeout der Background-Uploads (Idle-Timer, resettet bei Daten-
    /// Aktivitaet). Der URLSession-Default von 60 s killt grosse Uploads bei
    /// jedem laengeren Netz-Haenger (H5).
    static let uploadRequestTimeout: TimeInterval = 600

    // MARK: - Upload-Limits (PLAN.md Abschnitt 4 + 7)

    /// Harte serverseitige Obergrenze der Dauer: 6 Stunden (Pydantic le=21600).
    /// Filme darueber sind aktuell gar nicht uploadbar (waere Server-Aenderung).
    static let maxDurationSecondsCap = 21600

    /// Middleware-Cap des r2-stream-Pfads (ca. 11 GB). Darueber: Multipart-Fallback
    /// (r2-init / r2-complete) noetig. Wir setzen den App-Schwellwert konservativ
    /// auf 10 GB, damit knappe Faelle nicht in den Cap laufen.
    static let r2StreamMaxBytes: Int64 = 10 * 1_000_000_000

    /// Pydantic-Limit fuer r2-init (presigned, Bytes direkt zu R2): 32 GiB.
    static let r2InitMaxBytes: Int64 = 32 * 1_024 * 1_024 * 1_024

    /// Schwelle, ab der ein presigned-Single-PUT zu Multipart wechselt (4 GiB).
    static let presignedSinglePutMaxBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    /// Part-Groesse fuer presigned Multipart (256 MiB), wie in PLAN.md Abschnitt 7.
    static let multipartPartSize: Int64 = 256 * 1_024 * 1_024

    /// Mindest-Freiplatz auf der Systemplatte vor einem grossen Upload/Encode.
    /// Unter ~10 GB frei haengen R2-Uploads still (Memory feedback_r2_disk_first).
    static let minFreeDiskBytes: Int64 = 10 * 1_000_000_000

    // MARK: - Parallelitaet (PLAN.md Abschnitt 8)

    /// Genau ein aktiver Encode-Slot (ein 4K-Encode saettigt CPU/Media-Engine).
    static let encodeConcurrency = 1

    /// 1-2 parallele Uploads. Der Server-Semaphore fuer r2-stream ist global 2.
    static let uploadConcurrency = 2

    /// Maximale automatische Retry-Versuche pro Item, bevor es endgueltig failed.
    static let maxRetries = 3

    // MARK: - cf-refresh-Polling-Backoff (PLAN.md Abschnitt 7)

    /// Start-Intervall des cf-refresh-Pollings.
    static let cfRefreshInitialDelay: TimeInterval = 3
    /// Maximales Intervall (Backoff-Deckel).
    static let cfRefreshMaxDelay: TimeInterval = 30
    /// Faktor pro Backoff-Schritt.
    static let cfRefreshBackoffFactor: Double = 1.6
    /// Gesamt-Timeout des Pollings (Sicherheitsabbruch).
    static let cfRefreshTimeout: TimeInterval = 60 * 60

    // MARK: - Encode-Defaults (PLAN.md Abschnitt 5)

    /// AAC-Audio-Bitrate fuer alle Encode-Pfade.
    static let audioBitrate = "192k"

    /// Default-Qualitaetswert (q:v) fuer h264_videotoolbox (Review-schnell).
    static let videotoolboxQuality = 60

    /// CRF fuer den libx264-Maximalqualitaetspfad (4K-Endprodukt).
    static let x264CRF = 18

    // MARK: - ffmpeg-Bundle

    /// Name des ffmpeg-Binaries im App-Bundle (Resources/ffmpeg/).
    static let ffmpegBinaryName = "ffmpeg"
    /// Name des ffprobe-Binaries im App-Bundle (Resources/ffmpeg/).
    static let ffprobeBinaryName = "ffprobe"

    /// Entwicklungs-Fallback-Pfade, falls die Binaries (noch) nicht gebuendelt
    /// sind. Nur fuer lokale Entwicklung gedacht, nie fuer den Vertrieb.
    static let homebrewFFmpegPath = "/opt/homebrew/bin/ffmpeg"
    static let homebrewFFprobePath = "/opt/homebrew/bin/ffprobe"
}
