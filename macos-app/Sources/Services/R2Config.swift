// R2Config.swift
//
// Nicht-geheime Konfiguration fuer den S3-kompatiblen R2-Upload (Ziel B / Track B):
// Account-ID, Bucket, Endpoint und Region. Wird in UserDefaults gehalten.
// Die geheimen Zugangsdaten (Access-Key-ID + Secret) liegen NICHT hier, sondern in
// der Keychain (siehe TokenStore.r2Credentials()).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import Foundation

/// S3-kompatible R2-Konfiguration (ohne Geheimnisse). Sendable + Codable, damit sie
/// als JSON in UserDefaults persistiert und zwischen Actors gereicht werden kann.
struct R2Config: Sendable, Codable {

    /// Cloudflare-Account-ID (32-stelliger Hex-String).
    var accountId: String
    /// Ziel-Bucket (S3-kompatibel), z.B. "cinereview".
    var bucket: String
    /// S3-Endpoint, z.B. "https://<account-id>.r2.cloudflarestorage.com".
    var endpoint: String
    /// SigV4-Region. Bei R2 in der Regel "auto" (wie das Backend, app/r2.py).
    var region: String

    init(accountId: String = "", bucket: String = "", endpoint: String = "", region: String = "auto") {
        self.accountId = accountId
        self.bucket = bucket
        self.endpoint = endpoint
        self.region = region
    }

    // MARK: - Vollstaendigkeit

    /// True, wenn alle Pflichtfelder gesetzt sind (region hat einen Default).
    var isComplete: Bool {
        func filled(_ s: String) -> Bool {
            !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return filled(accountId) && filled(bucket) && filled(endpoint) && filled(region)
    }

    // MARK: - Persistenz (UserDefaults)

    /// UserDefaults-Schluessel der serialisierten Konfiguration.
    static let userDefaultsKey = "bdrop.r2config"

    /// Laedt die Konfiguration aus UserDefaults (nil, wenn nie gespeichert / kaputt).
    static func load(from defaults: UserDefaults = .standard) -> R2Config? {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(R2Config.self, from: data)
    }

    /// Speichert die Konfiguration als JSON in UserDefaults.
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }
}
