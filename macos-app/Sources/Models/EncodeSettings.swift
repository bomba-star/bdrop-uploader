// EncodeSettings.swift
//
// Snapshot der Encode-Entscheidung pro Item. Wird im QueueItem als JSON
// persistiert, damit ein Retry exakt dieselben Parameter nutzt.
// Setzt PLAN.md Abschnitt 5 (Encode-Strategie) und Abschnitt 8 (encodeSettings-Snapshot) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

/// Welcher konkrete ffmpeg-Pfad fuer dieses Item gewaehlt wurde.
enum EncodePlan: String, Codable, Sendable {
    /// Quelle bereits CF-tauglich -> nur Faststart-Remux (`-c copy +faststart`).
    case smartRemux
    /// Hardware-H.264 (h264_videotoolbox), Review-schnell.
    case hardwareH264
    /// Software-H.264 (libx264 -preset slow -crf 18), maximale Qualitaet.
    case softwareX264
    /// TODO(Ziel B): lokale HLS-Ladder. Noch nicht implementiert.
    case hlsLadder

    var germanLabel: String {
        switch self {
        case .smartRemux:   return "Schnell-Remux (kein Neu-Encode)"
        case .hardwareH264: return "Hardware-H.264"
        case .softwareX264: return "Software-H.264 (max. Qualität)"
        case .hlsLadder:    return "HLS-Ladder (4K)"
        }
    }
}

/// Eingefrorener Encode-Plan eines Items. Codable, weil er als JSON-String im
/// SwiftData-Model abgelegt wird.
struct EncodeSettings: Codable, Sendable, Equatable {
    /// Der konkrete gewaehlte ffmpeg-Pfad.
    var plan: EncodePlan
    /// Die vom Nutzer gewuenschte Zielqualitaet (beeinflusst hardware vs. software).
    var quality: EncodeQuality
    /// Ob die Quelle laut Probe schon CF-tauglich war (-> Smart-Remux moeglich).
    var sourceWasCompatible: Bool
    /// Video-Tag: avc1 fuer H.264, hvc1 fuer HEVC-Durchreichen (PLAN.md Abschnitt 5).
    var videoTag: String
    /// Ob der Audio-Stream der Quelle nicht MP4-nativ ist und beim Remux nach AAC
    /// umcodiert werden muss (PLAN.md Abschnitt 5: smartRemux-Audio-Sicherheit).
    var audioNeedsTranscode: Bool

    init(
        plan: EncodePlan,
        quality: EncodeQuality,
        sourceWasCompatible: Bool,
        videoTag: String = "avc1",
        audioNeedsTranscode: Bool = false
    ) {
        self.plan = plan
        self.quality = quality
        self.sourceWasCompatible = sourceWasCompatible
        self.videoTag = videoTag
        self.audioNeedsTranscode = audioNeedsTranscode
    }

    /// JSON-Repraesentation fuer die Persistenz.
    func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Wiederherstellung aus persistiertem JSON.
    static func decode(from json: String?) -> EncodeSettings? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EncodeSettings.self, from: data)
    }
}
