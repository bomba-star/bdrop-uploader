// ProbeService.swift
//
// Ruft ffprobe via Process auf, decodiert den JSON-Output und klassifiziert,
// ob eine Quelle CF-tauglich (Smart-Remux), encode-noetig oder abzulehnen ist.
// Setzt PLAN.md Abschnitt 5 (Encode-Strategie) und Abschnitt 10 (ProbeService) um.
// Die App ist laut PLAN.md Abschnitt 4 die EINZIGE echte Codec-Schranke.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

/// Ergebnis einer ffprobe-Analyse, bereits klassifiziert.
struct ProbeResult: Sendable {
    var codec: String
    var pixelFormat: String
    var bitDepth: Int
    /// Effektive Anzeige-Breite: bei 90/270-Grad-Rotation bereits mit der Hoehe
    /// getauscht (Fix H1). Alle Aufloesungs-Entscheidungen rechnen mit diesem Wert.
    var width: Int
    /// Effektive Anzeige-Hoehe (siehe width).
    var height: Int
    /// Rotation aus der Display-Matrix (side_data_list) bzw. tags.rotate,
    /// normalisiert auf 0/90/180/270 (Fix H1).
    var rotationDegrees: Int
    var durationSeconds: Double
    var hasAudio: Bool
    /// Codec des ersten Audio-Streams (z.B. "aac", "pcm_s16le"); nil wenn kein Audio.
    var audioCodec: String?
    /// color_transfer des Videostreams (z.B. "smpte2084", "arib-std-b67"); leer wenn unbekannt.
    var colorTransfer: String
    /// color_primaries des Videostreams (z.B. "bt2020"); leer wenn unbekannt.
    var colorPrimaries: String
    /// Ob die Quelle HDR ist: PQ/HLG-Transfer oder bt2020-Primaries mit >= 10 bit (Fix H2).
    /// HDR durch die 8-bit-SDR-Encode-Pfade liefert sichtbar falsche Farben.
    var isHDR: Bool
    /// Roher ffprobe-JSON (wird im QueueItem persistiert).
    var rawJSON: String

    enum Classification: Sendable {
        /// Bereits CF-tauglich (H.264/HEVC, 8-bit, yuv420p) -> Smart-Remux.
        case compatible
        /// Encode noetig (ProRes, 10-bit, 4:2:2, exotisch).
        case needsEncode
        /// Nicht uploadbar (Bilddatei, r3d, braw, nicht abspielbar).
        case reject(reason: String)
    }

    var classification: Classification
}

/// Fehler die der ProbeService werfen kann.
enum ProbeError: LocalizedError {
    case binaryNotFound
    case processFailed(stderr: String)
    case noVideoStream
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "ffprobe wurde nicht gefunden (weder im Bundle noch unter /opt/homebrew/bin)."
        case .processFailed(let stderr):
            return "ffprobe ist fehlgeschlagen: \(stderr)"
        case .noVideoStream:
            return "Die Datei enthält keinen abspielbaren Videostream."
        case .invalidJSON:
            return "Der ffprobe-Output konnte nicht gelesen werden."
        }
    }
}

/// Liest Codec/Pixelformat/Bittiefe/Aufloesung/Dauer und klassifiziert die Quelle.
struct ProbeService: Sendable {

    /// Codecs die Cloudflare Stream ohne Re-Encode akzeptiert (PLAN.md Abschnitt 5).
    private static let compatibleVideoCodecs: Set<String> = ["h264", "hevc"]

    /// Pixelformate die als 8-bit 4:2:0 gelten (Smart-Remux-tauglich).
    private static let compatiblePixelFormats: Set<String> = ["yuv420p", "yuvj420p"]

    /// Container/Codecs die wir sofort ablehnen (RAW-Kamera-Formate, Bilder).
    private static let rejectExtensions: Set<String> = ["r3d", "braw", "ari", "arx", "dpx", "jpg", "jpeg", "png", "tiff", "heic"]

    /// Fuehrt ffprobe aus und liefert ein klassifiziertes Ergebnis.
    /// Async: der blockierende ffprobe-Lauf (waitUntilExit) wird auf eine
    /// Hintergrund-Queue ausgelagert, damit der MainActor-Aufrufer (QueueStore)
    /// nicht einfriert - gleiches Muster wie EncodeService.generateThumbnail (Fix H9).
    /// - Parameter url: file://-URL der Quelldatei (Security-Scoped Zugriff muss
    ///   vom Aufrufer bereits aktiv sein).
    func probe(url: URL) async throws -> ProbeResult {
        // Schneller Endungs-Reject vor dem teuren Prozess.
        let ext = url.pathExtension.lowercased()
        if Self.rejectExtensions.contains(ext) {
            return ProbeResult(
                codec: ext, pixelFormat: "", bitDepth: 0, width: 0, height: 0,
                rotationDegrees: 0, durationSeconds: 0, hasAudio: false, audioCodec: nil,
                colorTransfer: "", colorPrimaries: "", isHDR: false, rawJSON: "",
                classification: .reject(reason: "Format \(ext.uppercased()) wird nicht unterstützt (RAW/Bild)."))
        }

        let ffprobe = try FFmpegLocator.ffprobeURL()

        let args = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]

        let (status, stdout, stderr) = try await Self.runOffMain(executable: ffprobe, arguments: args)
        guard status == 0 else {
            throw ProbeError.processFailed(stderr: stderr.trimmedTail())
        }

        guard let data = stdout.data(using: .utf8),
              let probe = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            throw ProbeError.invalidJSON
        }

        guard let video = probe.streams.first(where: { $0.codec_type == "video" }) else {
            throw ProbeError.noVideoStream
        }

        let codec = (video.codec_name ?? "").lowercased()
        let pixFmt = (video.pix_fmt ?? "").lowercased()
        let bitDepth = Self.bitDepth(forPixelFormat: pixFmt, fallback: video.bits_per_raw_sample)
        // Rotation aus der Display-Matrix (side_data_list), tags.rotate als Fallback.
        // Bei 90/270 Grad sind die Anzeige-Masse vertauscht (iPhone-Hochkant, Fix H1);
        // ffmpeg dreht beim Neu-Encode via autorotate mit, iw/ih im Filter passen dann.
        let rotation = Self.rotationDegrees(for: video)
        let rawWidth = video.width ?? 0
        let rawHeight = video.height ?? 0
        let swapDimensions = (rotation == 90 || rotation == 270)
        let width = swapDimensions ? rawHeight : rawWidth
        let height = swapDimensions ? rawWidth : rawHeight
        let hasAudio = probe.streams.contains { $0.codec_type == "audio" }
        // Codec des ersten Audio-Streams (fuer die smartRemux-Audio-Entscheidung).
        let audioCodec = probe.streams.first(where: { $0.codec_type == "audio" })?.codec_name
        // HDR-Erkennung (Fix H2): PQ/HLG-Transfer oder Rec.2020-Primaries mit 10 bit.
        let colorTransfer = (video.color_transfer ?? "").lowercased()
        let colorPrimaries = (video.color_primaries ?? "").lowercased()
        let isHDR = Self.isHDR(transfer: colorTransfer, primaries: colorPrimaries, bitDepth: bitDepth)

        // Dauer: zuerst format.duration, sonst stream.duration.
        let duration = Double(probe.format?.duration ?? video.duration ?? "0") ?? 0

        let classification = Self.classify(
            codec: codec, pixelFormat: pixFmt, bitDepth: bitDepth, width: width, height: height)

        return ProbeResult(
            codec: codec,
            pixelFormat: pixFmt,
            bitDepth: bitDepth,
            width: width,
            height: height,
            rotationDegrees: rotation,
            durationSeconds: duration,
            hasAudio: hasAudio,
            audioCodec: audioCodec,
            colorTransfer: colorTransfer,
            colorPrimaries: colorPrimaries,
            isHDR: isHDR,
            rawJSON: stdout,
            classification: classification)
    }

    /// Fuehrt den blockierenden ProcessRunner-Lauf auf einer Utility-Queue aus,
    /// damit weder der MainActor noch ein Cooperative-Pool-Thread waehrend
    /// waitUntilExit() blockiert (Fix H9). Alle gefangenen Werte sind Sendable.
    private static func runOffMain(
        executable: URL,
        arguments: [String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, stdout: String, stderr: String), Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try ProcessRunner.run(executable: executable, arguments: arguments)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Klassifikation

    private static func classify(codec: String, pixelFormat: String, bitDepth: Int, width: Int, height: Int) -> ProbeResult.Classification {
        guard width > 0, height > 0 else {
            return .reject(reason: "Keine gültige Auflösung im Videostream.")
        }
        let is8bit = bitDepth <= 8
        let codecOK = compatibleVideoCodecs.contains(codec)
        let pixOK = compatiblePixelFormats.contains(pixelFormat)

        if codecOK && pixOK && is8bit {
            return .compatible
        }
        // Alles andere ist encodierbar (ProRes, 10-bit, 4:2:2, exotisch).
        return .needsEncode
    }

    /// Leitet die Bittiefe aus dem Pixelformat ab, mit Fallback auf bits_per_raw_sample.
    private static func bitDepth(forPixelFormat pix: String, fallback: String?) -> Int {
        if pix.contains("p10") || pix.contains("10le") || pix.contains("10be") { return 10 }
        if pix.contains("p12") || pix.contains("12le") || pix.contains("12be") { return 12 }
        if pix.contains("p16") { return 16 }
        if let f = fallback, let n = Int(f), n > 0 { return n }
        return 8
    }

    /// Liest die Rotation eines Videostreams: zuerst das rotation-Feld der
    /// Display-Matrix in side_data_list (auch negative Werte: -90, 90, 180, 270),
    /// sonst tags.rotate als Fallback. Normalisiert auf 0/90/180/270 (Fix H1).
    private static func rotationDegrees(for stream: FFProbeOutput.Stream) -> Int {
        var value: Double?
        if let sideData = stream.side_data_list {
            value = sideData.compactMap({ $0.rotation }).first
        }
        if value == nil, let tag = stream.tags?.rotate {
            value = Double(tag)
        }
        guard let value, value.isFinite else { return 0 }
        // Auf den naechsten 90-Grad-Quadranten runden und in 0..<360 normalisieren.
        let quadrant = ((Int((value / 90).rounded()) % 4) + 4) % 4
        return quadrant * 90
    }

    /// HDR-Erkennung (Fix H2): PQ (smpte2084) oder HLG (arib-std-b67) Transfer,
    /// sonst Rec.2020-Primaries mit >= 10 bit. Wide-Gamut-SDR (bt2020 + 8 bit) zaehlt nicht.
    private static func isHDR(transfer: String, primaries: String, bitDepth: Int) -> Bool {
        if transfer == "smpte2084" || transfer == "arib-std-b67" { return true }
        return primaries == "bt2020" && bitDepth >= 10
    }
}

// MARK: - ffprobe-JSON-Decodables

/// Schlanke Decodable-Struktur fuer den relevanten Teil des ffprobe-JSON.
private struct FFProbeOutput: Decodable {
    struct Stream: Decodable {
        /// Ein Eintrag aus side_data_list; relevant ist nur die Display-Matrix
        /// mit ihrem rotation-Feld (Fix H1).
        struct SideData: Decodable {
            var side_data_type: String?
            var rotation: Double?
        }
        /// Stream-Tags; rotate ist der Legacy-Rotations-Fallback aelterer Dateien.
        struct Tags: Decodable {
            var rotate: String?
        }
        var codec_type: String?
        var codec_name: String?
        var pix_fmt: String?
        var bits_per_raw_sample: String?
        var width: Int?
        var height: Int?
        var duration: String?
        var color_transfer: String?
        var color_primaries: String?
        var side_data_list: [SideData]?
        var tags: Tags?
    }
    struct Format: Decodable {
        var duration: String?
    }
    var streams: [Stream]
    var format: Format?
}
