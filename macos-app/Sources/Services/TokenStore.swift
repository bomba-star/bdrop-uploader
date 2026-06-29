// TokenStore.swift
//
// Speichert den Admin-Bearer-Token (und optional R2-Credentials fuer Ziel B)
// in der macOS-Keychain via Keychain Services. Lesen/Schreiben/Loeschen.
// Setzt PLAN.md Abschnitt 10 (TokenStore) und Abschnitt 4 (Auth) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Security.framework ist nur auf Apple-Plattformen verfuegbar.

import Foundation
import Security

/// Schluessel-/Dienst-Konstanten fuer die Keychain-Eintraege.
private enum KeychainKeys {
    static let service = "com.jonasbomba.bdropuploader"
    static let adminTokenAccount = "admin-bearer-token"
    // Ziel B (optional, noch nicht aktiv genutzt):
    static let r2AccessKeyAccount = "r2-access-key-id"
    static let r2SecretKeyAccount = "r2-secret-access-key"
}

/// Duenner, threadsicherer Wrapper um die generische Keychain-Passwort-API.
/// `@Observable`, damit die SettingsView reaktiv sehen kann, ob ein Token gesetzt ist.
@Observable
final class TokenStore: @unchecked Sendable {

    /// Reaktive Anzeige, ob aktuell ein Admin-Token hinterlegt ist (nicht der Token selbst).
    private(set) var hasAdminToken: Bool = false

    /// Reaktive Anzeige, ob R2-Credentials (Access-Key + Secret) hinterlegt sind.
    private(set) var hasR2Credentials: Bool = false

    init() {
        hasAdminToken = (adminToken() != nil)
        hasR2Credentials = (r2Credentials() != nil)
    }

    // MARK: - Admin-Token

    /// Liest den Admin-Bearer-Token aus der Keychain.
    func adminToken() -> String? {
        read(account: KeychainKeys.adminTokenAccount)
    }

    /// Schreibt (oder ersetzt) den Admin-Bearer-Token.
    @discardableResult
    func setAdminToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = write(account: KeychainKeys.adminTokenAccount, value: trimmed)
        hasAdminToken = ok && !trimmed.isEmpty
        return ok
    }

    /// Loescht den Admin-Token.
    @discardableResult
    func clearAdminToken() -> Bool {
        let ok = delete(account: KeychainKeys.adminTokenAccount)
        hasAdminToken = false
        return ok
    }

    // MARK: - R2-Credentials (Ziel B / Track B: 4K-HLS-Upload nach R2)

    /// Liest Access-Key-ID + Secret-Access-Key aus der Keychain (nil, wenn unvollstaendig).
    func r2Credentials() -> (accessKey: String, secretKey: String)? {
        guard let a = read(account: KeychainKeys.r2AccessKeyAccount),
              let s = read(account: KeychainKeys.r2SecretKeyAccount) else { return nil }
        return (a, s)
    }

    /// Schreibt (oder ersetzt) die R2-Credentials. Beide Werte werden getrimmt.
    @discardableResult
    func setR2Credentials(accessKey: String, secretKey: String) -> Bool {
        let a = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = write(account: KeychainKeys.r2AccessKeyAccount, value: a)
            && write(account: KeychainKeys.r2SecretKeyAccount, value: s)
        hasR2Credentials = ok && !a.isEmpty && !s.isEmpty
        return ok
    }

    /// Loescht die R2-Credentials aus der Keychain.
    @discardableResult
    func clearR2Credentials() -> Bool {
        let ok = delete(account: KeychainKeys.r2AccessKeyAccount)
            && delete(account: KeychainKeys.r2SecretKeyAccount)
        hasR2Credentials = false
        return ok
    }

    // MARK: - Keychain-Primitiven

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    @discardableResult
    private func write(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Erst loeschen, dann neu anlegen (idempotentes Upsert).
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Nur lesbar, wenn das Geraet entsperrt ist; bleibt auf diesem Geraet.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    private func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
