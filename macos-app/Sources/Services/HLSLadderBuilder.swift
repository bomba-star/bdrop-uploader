// HLSLadderBuilder.swift
//
// Baut die ffmpeg-Argumente fuer eine lokale, aspektgenaue adaptive HLS-Leiter
// (Ziel B, 4K), PLAN.md Abschnitt 6 und specs/2026-06-22-bdrop-r2-4k-hls-design.md.
// fMP4/CMAF, 6s-Segmente, keyframe-aligned, yuv420p 8-bit, AAC. Aus EINEM
// ffmpeg-Aufruf via split + per-Sprosse scale + -var_stream_map.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Die ffmpeg-Befehle folgen der Spec; eine echte Encode-Verifikation steht aus.

import Foundation

enum HLSLadderBuilder {

    /// Eine einzelne Sprosse der Leiter.
    /// `scaleWidth` ist die tatsaechliche Pixel-Breite (Hoehe wird aspektgenau
    /// abgeleitet, gerade). `name` ist der 16:9-Label-Name (Ordnername in der Ausgabe).
    struct Rung: Sendable {
        var name: String
        var scaleWidth: Int
        var crf: Int
        var maxrateMbps: Double
    }

    /// Standard-Leiter aus der Spec (oberste -> unterste). scaleWidth ist die
    /// 16:9-aequivalente Breite je Klasse; bei 2.40:1-Quellen ergibt scale=W:-2
    /// genau die Spec-Aufloesungen (3840x1600, 2560x1066, 1920x800, ...).
    static let standardRungs: [Rung] = [
        Rung(name: "2160w", scaleWidth: 3840, crf: 19, maxrateMbps: 30),
        Rung(name: "1440w", scaleWidth: 2560, crf: 20, maxrateMbps: 14),
        Rung(name: "1080w", scaleWidth: 1920, crf: 20, maxrateMbps: 8),
        Rung(name: "720w",  scaleWidth: 1280, crf: 21, maxrateMbps: 4),
        Rung(name: "480w",  scaleWidth: 854,  crf: 22, maxrateMbps: 1.8),
    ]

    /// Leitet die tatsaechlich zu erzeugenden Sprossen ab: keine Sprosse oberhalb
    /// der Quelle (kein Upscaling) und keine oberhalb des optionalen Qualitaets-Caps
    /// (`maxWidth`, z.B. 1920 fuer eine 1080p-Stufe). Ist die effektive Grenze
    /// kleiner als die kleinste Standard-Sprosse, wird eine native Sprosse erzeugt.
    static func rungs(forSourceWidth sourceWidth: Int, maxWidth: Int? = nil) -> [Rung] {
        let cap = min(sourceWidth, maxWidth ?? sourceWidth)
        let usable = standardRungs.filter { $0.scaleWidth <= cap }
        if usable.isEmpty {
            let w = max(2, cap - (cap % 2))
            return [Rung(name: "src", scaleWidth: w, crf: 20, maxrateMbps: 8)]
        }
        return usable
    }

    /// Ordnernamen der Varianten (zum Vorab-Anlegen der Unterordner).
    static func variantNames(forSourceWidth sourceWidth: Int, maxWidth: Int? = nil) -> [String] {
        rungs(forSourceWidth: sourceWidth, maxWidth: maxWidth).map(\.name)
    }

    /// Baut die vollstaendige ffmpeg-Argumentliste fuer die HLS-Leiter.
    /// Ausgabe-Layout: <outputDir>/master.m3u8 und je Sprosse
    /// <outputDir>/<name>/index.m3u8 + init.mp4 + seg_XXXXX.m4s.
    static func ffmpegArguments(input: URL, outputDir: URL, sourceWidth: Int, hasAudio: Bool, maxWidth: Int? = nil) -> [String] {
        let selected = rungs(forSourceWidth: sourceWidth, maxWidth: maxWidth)
        let n = selected.count
        let base = outputDir.path

        var args: [String] = ["-i", input.path]

        // filter_complex: in n Stroeme splitten, jeden aspektgenau skalieren.
        var filter = "[0:v]split=\(n)"
        for i in 0..<n { filter += "[s\(i)]" }
        filter += ";"
        for (i, r) in selected.enumerated() {
            filter += "[s\(i)]scale=\(r.scaleWidth):-2:flags=lanczos,setsar=1[v\(i)]"
            if i < n - 1 { filter += ";" }
        }
        args += ["-filter_complex", filter]

        // Mapping: je Sprosse der skalierte Video-Stream (+ Audio, falls vorhanden).
        for i in 0..<n {
            args += ["-map", "[v\(i)]"]
            if hasAudio { args += ["-map", "0:a:0"] }
        }

        // Globale Video-Codec-Einstellungen. yuv420p 8-bit (10-bit-Quelle wird
        // konvertiert; KEIN HDR-Tonemapping - SDR-Quellen wie geplant, HDR offen).
        // 6s-keyframe-aligned via force_key_frames (fps-unabhaengig), closed GOP.
        args += [
            "-c:v", "libx264",
            "-preset", "slow",
            "-pix_fmt", "yuv420p",
            "-profile:v", "high",
            "-sc_threshold", "0",
            "-force_key_frames", "expr:gte(t,n_forced*6)",
        ]
        // Pro-Sprosse Ratenkontrolle (capped CRF: crf + maxrate + bufsize).
        for (i, r) in selected.enumerated() {
            args += [
                "-crf:v:\(i)", "\(r.crf)",
                "-maxrate:v:\(i)", mbps(r.maxrateMbps),
                "-bufsize:v:\(i)", mbps(r.maxrateMbps * 2),
            ]
        }

        if hasAudio {
            args += ["-c:a", "aac", "-b:a", AppConfig.audioBitrate, "-ac", "2"]
        }

        // HLS-Muxing (fMP4/CMAF). var_stream_map gruppiert je Sprosse Video(+Audio)
        // und benennt den Ordner ueber name:.
        var varMap = ""
        for (i, r) in selected.enumerated() {
            varMap += hasAudio ? "v:\(i),a:\(i),name:\(r.name)" : "v:\(i),name:\(r.name)"
            if i < n - 1 { varMap += " " }
        }
        args += [
            "-f", "hls",
            "-hls_time", "6",
            "-hls_playlist_type", "vod",
            "-hls_segment_type", "fmp4",
            "-hls_flags", "independent_segments",
            "-hls_segment_filename", "\(base)/%v/seg_%05d.m4s",
            "-master_pl_name", "master.m3u8",
            "-var_stream_map", varMap,
        ]
        // Progress auf stdout, Output-Playlist-Muster.
        args += ["-progress", "pipe:1", "-nostats", "-y", "\(base)/%v/index.m3u8"]
        return args
    }

    /// Formatiert eine Mbit/s-Zahl als ffmpeg-Bitrate ("30M", "1.8M").
    private static func mbps(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))M" }
        return String(format: "%gM", value)
    }
}
