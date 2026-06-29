// R2Uploader.swift
//
// Laedt einen lokalen HLS-Baum nach Cloudflare R2 (S3-kompatibel) hoch. Signiert
// jeden PUT mit AWS Signature Version 4 (Service "s3"), Payload-Hash via CryptoKit
// (SHA256), Signing-Key via HMAC-SHA256-Kette. Kein Backend/Worker-Eingriff -
// reiner Objekt-Upload in den privaten Bucket im vom Worker erwarteten Layout
// hls/videos/<video_id>/<relativer-Pfad>.
//
// Bezug: track-b/mac-app-r2-upload.md (Komponenten SigV4Signer + R2Uploader).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Es werden hier keine echten Netzwerk-Calls ausgefuehrt. CryptoKit ist nur auf
// Apple-Plattformen verfuegbar.

import Foundation
import CryptoKit

/// Fehlerfaelle des R2-Uploads, sauber nach Kategorie getrennt.
enum R2UploadError: LocalizedError, Sendable {
    /// R2 ist nicht (vollstaendig) konfiguriert (Config oder Credentials fehlen/kaputt).
    case notConfigured
    /// Signatur-/URL-Aufbau fehlgeschlagen (lokaler Fehler, kein Retry sinnvoll).
    case signing(String)
    /// R2 hat einen HTTP-Fehler geliefert (Status + gekuerzter Body).
    case httpError(status: Int, body: String)
    /// Transport-/IO-Ebene (Netzwerk, Datei nicht lesbar).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "R2 ist nicht vollständig konfiguriert (Account-ID, Bucket, Endpoint, Zugangsschlüssel)."
        case .signing(let m):
            return "R2-Signatur fehlgeschlagen: \(m)"
        case .httpError(let s, let b):
            return "R2-Fehler (\(s)): \(b)"
        case .transport(let m):
            return "R2-Netzwerkfehler: \(m)"
        }
    }
}

/// Signiert und sendet S3-PUTs gegen R2. Value-Type, alle Felder `let` -> Sendable.
/// Credentials werden im Init uebergeben (aus der Keychain), nie aus Code/Defaults.
struct R2Uploader: Sendable {

    let config: R2Config
    let accessKeyId: String
    let secretAccessKey: String
    let session: URLSession

    /// Gleichzeitige PUTs (der Plan empfiehlt 4-6 bei ~4400 Segmenten).
    private static let maxConcurrentPuts = 5
    /// Versuche pro Datei bei transienten Fehlern (idempotenter PUT, gefahrlos wiederholbar).
    private static let maxAttempts = 3

    init(config: R2Config, accessKeyId: String, secretAccessKey: String, session: URLSession? = nil) {
        self.config = config
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 120
            cfg.timeoutIntervalForResource = 60 * 60
            cfg.httpMaximumConnectionsPerHost = R2Uploader.maxConcurrentPuts
            cfg.waitsForConnectivity = true
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Datei-Eintrag

    /// Eine hochzuladende Datei mit fertigem R2-Key. Sendable (URL/String/Bool).
    private struct UploadEntry: Sendable {
        let fileURL: URL
        let key: String
        /// master.m3u8 wird ZULETZT hochgeladen, damit es nie auf fehlende Teile zeigt.
        let isMaster: Bool
    }

    // MARK: - Oeffentlicher Einstieg

    /// Laedt den kompletten Baum unter `localDir` nach R2.
    /// - Parameters:
    ///   - localDir: Wurzel des lokalen HLS-Ordners (enthaelt master.m3u8 + Spuren).
    ///   - videoID: versions.video_id der Ziel-Version -> Key-Prefix hls/videos/<id>/.
    ///   - onProgress: Fortschritt 0.0..1.0 = erledigte Dateien / Gesamtzahl.
    func uploadTree(
        localDir: URL,
        videoID: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard config.isComplete, !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw R2UploadError.notConfigured
        }

        let entries = try Self.enumerateFiles(in: localDir, videoID: videoID)
        let total = entries.count
        guard total > 0 else {
            throw R2UploadError.transport("Keine Dateien zum Hochladen im HLS-Ordner (\(localDir.lastPathComponent)).")
        }

        // master.m3u8 zuletzt: erst Segmente + Spur-Playlists, dann das Master-Manifest.
        let primary = entries.filter { !$0.isMaster }
        let deferred = entries.filter { $0.isMaster }

        var completed = 0
        onProgress(0)

        // Phase 1: alles ausser master.m3u8 mit begrenzter Parallelitaet.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = primary.makeIterator()
            var running = 0
            // Anfangsfenster fuellen.
            while running < Self.maxConcurrentPuts, let entry = iterator.next() {
                group.addTask { try await self.putObject(fileURL: entry.fileURL, key: entry.key) }
                running += 1
            }
            // Abarbeiten und nachschieben.
            while running > 0 {
                try Task.checkCancellation()
                _ = try await group.next()
                running -= 1
                completed += 1
                onProgress(Double(completed) / Double(total))
                if let entry = iterator.next() {
                    group.addTask { try await self.putObject(fileURL: entry.fileURL, key: entry.key) }
                    running += 1
                }
            }
        }

        // Phase 2: master.m3u8 (in der Regel genau eine Datei) zuletzt.
        for entry in deferred {
            try Task.checkCancellation()
            try await putObject(fileURL: entry.fileURL, key: entry.key)
            completed += 1
            onProgress(Double(completed) / Double(total))
        }
    }

    // MARK: - Datei-Enumeration

    /// Listet alle regulaeren Dateien unter `localDir` rekursiv und bildet die R2-Keys.
    private static func enumerateFiles(in localDir: URL, videoID: String) throws -> [UploadEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: localDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            throw R2UploadError.transport("Konnte den HLS-Ordner nicht lesen: \(localDir.path)")
        }
        // Die vom Enumerator gelieferten URLs haengen am localDir.path -> Prefix-Schnitt
        // liefert den relativen Pfad (1:1 ins Ziel-Layout uebernommen).
        let basePath = localDir.path
        var entries: [UploadEntry] = []
        for case let fileURL as URL in enumerator {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            let full = fileURL.path
            guard full.hasPrefix(basePath) else { continue }
            var rel = String(full.dropFirst(basePath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty else { continue }
            let key = "hls/videos/\(videoID)/\(rel)"
            entries.append(UploadEntry(fileURL: fileURL, key: key, isMaster: rel == "master.m3u8"))
        }
        return entries
    }

    // MARK: - Einzelner PUT (mit Retry)

    /// PUTtet eine Datei; bei transienten Fehlern bis zu maxAttempts mit Backoff.
    private func putObject(fileURL: URL, key: String) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await putObjectOnce(fileURL: fileURL, key: key)
                return
            } catch let error as R2UploadError where Self.isTransient(error) && attempt < Self.maxAttempts {
                // Linearer Backoff: 1.5s, 3.0s, ...
                let delaySeconds = Double(attempt) * 1.5
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                // naechster Versuch
            }
        }
    }

    /// Ob ein Fehler einen Retry rechtfertigt (Netzwerk oder 429/5xx). 4xx (z.B. 403
    /// Signaturfehler) wird NICHT wiederholt - das waere sinnlos.
    private static func isTransient(_ error: R2UploadError) -> Bool {
        switch error {
        case .transport:
            return true
        case .httpError(let status, _):
            return status == 429 || (500...599).contains(status)
        case .notConfigured, .signing:
            return false
        }
    }

    /// Genau ein signierter PUT. Body wird datei-basiert gesendet (speicherschonend);
    /// der Payload-Hash kommt aus dem (gemappten) Datei-Inhalt.
    private func putObjectOnce(fileURL: URL, key: String) async throws {
        let payloadHash = try Self.sha256Hex(ofFileAt: fileURL)
        let contentType = Self.contentType(for: fileURL)
        let request = try makeSignedPutRequest(key: key, payloadHash: payloadHash, contentType: contentType)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL)
        } catch {
            throw R2UploadError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw R2UploadError.transport("Keine HTTP-Antwort von R2.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw R2UploadError.httpError(status: http.statusCode, body: String(text.prefix(500)))
        }
    }

    // MARK: - SigV4-Request-Bau

    /// Baut einen SigV4-signierten PUT-Request (Path-Style: /<bucket>/<key>).
    private func makeSignedPutRequest(key: String, payloadHash: String, contentType: String) throws -> URLRequest {
        // Endpoint defensiv normalisieren: fehlendes Schema -> https annehmen.
        var endpointString = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = endpointString.lowercased()
        if !lower.hasPrefix("http://"), !lower.hasPrefix("https://") {
            endpointString = "https://" + endpointString
        }
        guard let endpointURL = URL(string: endpointString),
              let scheme = endpointURL.scheme,
              let host = endpointURL.host else {
            throw R2UploadError.notConfigured
        }
        // Host-Header inkl. Port, falls (untypisch) gesetzt - muss exakt mit dem
        // signierten Wert uebereinstimmen.
        let hostHeader = endpointURL.port.map { "\(host):\($0)" } ?? host

        // Kanonischer URI im Path-Style: jeder Pfad-Abschnitt RFC-3986-encodiert,
        // Schraegstriche bleiben Trenner. (Fuer das HLS-Layout faellt praktisch keine
        // Kodierung an - nur unreservierte Zeichen.)
        let fullPath = "\(config.bucket)/\(key)"
        let canonicalURI = "/" + fullPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }
            .joined(separator: "/")

        guard let url = URL(string: "\(scheme)://\(hostHeader)\(canonicalURI)") else {
            throw R2UploadError.signing("Konnte Ziel-URL nicht bilden.")
        }

        let (amzDate, dateStamp) = Self.amzDates(from: Date())
        let region = config.region.isEmpty ? "auto" : config.region
        let service = "s3"
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        // Signierte Header: host, x-amz-content-sha256, x-amz-date (alphabetisch, klein).
        let canonicalHeaders =
            "host:\(hostHeader)\n" +
            "x-amz-content-sha256:\(payloadHash)\n" +
            "x-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

        // Kanonische Anfrage (leere Query). canonicalHeaders endet bereits auf \n,
        // das join fuegt die geforderte Leerzeile danach ein.
        let canonicalRequest = [
            "PUT",
            canonicalURI,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        // Signing-Key-Kette: kDate -> kRegion -> kService -> kSigning.
        let kDate = Self.hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hexEncode(Self.hmac(key: kSigning, data: Data(stringToSign.utf8)))

        let authorization = "AWS4-HMAC-SHA256 " +
            "Credential=\(accessKeyId)/\(scope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        // Host setzt URLSession selbst aus der URL (== hostHeader); nicht manuell setzen.
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return req
    }

    // MARK: - Content-Type-Mapping

    /// Content-Type nach Datei-Endung. Der Worker setzt den Typ ohnehin selbst,
    /// wir laden aber sauber typisiert hoch.
    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp4":  return "video/mp4"
        case "m4s":  return "video/iso.segment"   // fMP4/CMAF-Segment
        case "ts":   return "video/mp2t"
        default:     return "application/octet-stream"
        }
    }

    // MARK: - Krypto-Helfer (CryptoKit)

    /// SHA256-Hex einer im Speicher liegenden Datenmenge.
    private static func sha256Hex(_ data: Data) -> String {
        hexEncode(Data(SHA256.hash(data: data)))
    }

    /// SHA256-Hex einer Datei (gemappt, speicherschonend bei grossen Segmenten).
    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return sha256Hex(data)
        } catch {
            throw R2UploadError.transport("Datei nicht lesbar (\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    /// HMAC-SHA256 -> rohe Bytes (fuer die Signing-Key-Kette).
    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Bytes als Kleinbuchstaben-Hex.
    private static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC-3986-Kodierung eines einzelnen Pfad-Abschnitts (Schraegstriche kommen hier
    /// nie an, da segmentweise aufgerufen). Unreserviert bleibt: A-Z a-z 0-9 - . _ ~
    private static func uriEncode(_ segment: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    // MARK: - Datums-Helfer

    /// Liefert (x-amz-date, dateStamp) in UTC. Manuell formatiert -> kein DateFormatter
    /// (Sendable-/Locale-frei). amzDate = yyyyMMddTHHmmssZ, dateStamp = yyyyMMdd.
    private static func amzDates(from date: Date) -> (amzDate: String, dateStamp: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateStamp = String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let amzDate = String(format: "%@T%02d%02d%02dZ", dateStamp, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return (amzDate, dateStamp)
    }
}
