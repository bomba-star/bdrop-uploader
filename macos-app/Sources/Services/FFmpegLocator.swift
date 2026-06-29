// FFmpegLocator.swift
//
// Loest die Pfade zu ffmpeg und ffprobe auf: zuerst aus dem App-Bundle
// (Contents/Resources/ffmpeg/), mit Entwicklungs-Fallback auf /opt/homebrew/bin.
// Setzt PLAN.md Abschnitt 10 (ffmpeg-Bundle) und die FFMPEG-BUNDLING-Vorgabe um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

enum FFmpegLocator {

    /// URL des ffmpeg-Binaries. Bundle zuerst, dann Homebrew-Fallback.
    static func ffmpegURL() throws -> URL {
        try locate(
            bundleName: AppConfig.ffmpegBinaryName,
            homebrewPath: AppConfig.homebrewFFmpegPath)
    }

    /// URL des ffprobe-Binaries. Bundle zuerst, dann Homebrew-Fallback.
    static func ffprobeURL() throws -> URL {
        try locate(
            bundleName: AppConfig.ffprobeBinaryName,
            homebrewPath: AppConfig.homebrewFFprobePath)
    }

    private static func locate(bundleName: String, homebrewPath: String) throws -> URL {
        // 1) Im App-Bundle unter Resources/ffmpeg/.
        if let url = Bundle.main.url(
            forResource: bundleName,
            withExtension: nil,
            subdirectory: "ffmpeg"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        // Fallback: manche Build-Konfigs flachen die Resource-Struktur ab.
        if let url = Bundle.main.url(forResource: bundleName, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        // 2) Entwicklungs-Fallback auf Homebrew (nur lokal, nie im Vertrieb).
        if FileManager.default.isExecutableFile(atPath: homebrewPath) {
            return URL(fileURLWithPath: homebrewPath)
        }
        throw ProbeError.binaryNotFound
    }
}
