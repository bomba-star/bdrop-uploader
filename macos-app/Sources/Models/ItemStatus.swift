// ItemStatus.swift
//
// Status- und Ziel-Enums fuer ein QueueItem.
// Setzt PLAN.md Abschnitt 8 (Status-Enum) und Abschnitt 2 (Ziel A/B) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

/// Lebenszyklus eines Items in der Queue.
///
/// Reihenfolge des Normalpfads:
/// queued -> probing -> encoding -> encoded -> uploading -> serverProcessing -> done.
/// `failed` und `paused` koennen aus den meisten Phasen erreicht werden.
enum ItemStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case probing
    case encoding
    case encoded
    case uploading
    case serverProcessing
    case done
    case failed
    case paused

    /// Deutsche, UI-sichtbare Bezeichnung der Phase (echte Umlaute).
    var germanLabel: String {
        switch self {
        case .queued:           return "In Warteschlange"
        case .probing:          return "Prüfen"
        case .encoding:         return "Encodieren"
        case .encoded:          return "Encodiert"
        case .uploading:        return "Hochladen"
        case .serverProcessing: return "Server verarbeitet"
        case .done:             return "Fertig"
        case .failed:           return "Fehlgeschlagen"
        case .paused:           return "Pausiert"
        }
    }

    /// Ob das Item noch aktiv durch die Pipeline laeuft (nicht End- oder Fehlerzustand).
    var isActive: Bool {
        switch self {
        case .done, .failed, .paused:
            return false
        default:
            return true
        }
    }

    /// Ob ein Retry sinnvoll ist.
    var isRetryable: Bool {
        self == .failed || self == .paused
    }
}

/// Ausgabe-Ziel eines Jobs: Format (H.264 vs HLS) und Bestimmung (Upload vs lokal).
enum UploadTarget: String, Codable, CaseIterable, Sendable {
    /// H.264-Master zu Cloudflare Stream (Stream bis 1080p, 4K als Download).
    case cfStream

    /// Lokale HLS-Leiter nach R2 fuer echtes 4K-Streaming (R2-Upload folgt).
    case r2HLS

    /// Nur umwandeln: H.264-Master lokal speichern, kein Upload.
    case localH264

    /// Nur umwandeln: 4K-HLS-Leiter lokal speichern, kein Upload.
    case localHLS

    var germanLabel: String {
        switch self {
        case .cfStream:  return "Cloudflare Stream (Upload)"
        case .r2HLS:     return "4K-HLS auf R2 (Upload)"
        case .localH264: return "Nur umwandeln: H.264-Master (lokal)"
        case .localHLS:  return "Nur umwandeln: 4K-HLS-Leiter (lokal)"
        }
    }

    /// Erzeugt eine HLS-Leiter (statt eines H.264-Einzelmasters).
    var producesHLS: Bool {
        self == .r2HLS || self == .localHLS
    }

    /// Wird lokal gespeichert statt hochgeladen.
    var isLocal: Bool {
        self == .localH264 || self == .localHLS
    }
}

/// Gewuenschte Encode-Qualitaet pro Job (PLAN.md Abschnitt 5).
/// Die Stufe bestimmt Encoder (Hardware/Software), Aufloesungs-Obergrenze und -
/// bei Ziel B - die Tiefe der HLS-Leiter.
enum EncodeQuality: String, Codable, CaseIterable, Sendable {
    /// Proxy: schneller Hardware-Encode, auf 720p begrenzt (Sichtung/Schnellcheck).
    case proxy

    /// Review: Hardware h264_videotoolbox, auf 1080p begrenzt. Default.
    case reviewFast

    /// Hoch: libx264 (bessere Qualitaet pro Bit), auf 1080p begrenzt.
    case high

    /// 4K-Master: libx264 -preset slow -crf 18, maximale Qualitaet, keine Grenze.
    case archiveBest

    var germanLabel: String {
        switch self {
        case .proxy:       return "Proxy (schnell, 720p)"
        case .reviewFast:  return "Review (1080p, Hardware)"
        case .high:        return "Hoch (1080p, Software)"
        case .archiveBest: return "4K-Master (max. Qualität)"
        }
    }

    /// Nutzt die Hardware-Engine (h264_videotoolbox) statt libx264.
    var usesHardware: Bool {
        self == .proxy || self == .reviewFast
    }

    /// Obergrenze der Ausgabe-Breite (nil = keine Begrenzung, bis Quelle/4K).
    var maxWidth: Int? {
        switch self {
        case .proxy:                  return 1280
        case .reviewFast, .high:      return 1920
        case .archiveBest:            return nil
        }
    }

    /// Obergrenze der HLS-Leiter (gleiche Caps wie der Einzeldatei-Pfad).
    var hlsMaxWidth: Int? { maxWidth }

    /// Smart-Remux nur erlaubt, wenn die Stufe keine Skalierung verlangt.
    var allowRemux: Bool { maxWidth == nil }
}
