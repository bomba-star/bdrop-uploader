// MultipartUploader.swift
//
// Laedt einen grossen Master (ueber dem r2-stream-Cap, > 10 GB) in presigned
// Parts DIREKT nach R2 (S3-Multipart). Die Part-URLs kommen vom Backend
// (r2-init), die ETags der PUT-Antworten gehen gesammelt an r2-complete.
// Sequenziell: ein Part nach dem anderen, gelesen per FileHandle ab Offset
// (nie die ganze Datei im Speicher, nur ein Part von typischerweise 256 MiB).
// Vordergrund-URLSession: stirbt die App, stirbt der Transfer - der Aufrufer
// (QueueStore) zeigt dafuer den "App offen lassen"-Hinweis.
//
// Muster: R2Uploader.swift (Fehler-Taxonomie, Retry mit Backoff, kooperative
// Cancellation an den Schleifenkoepfen). Verhaltens-Referenz: r2UploadVideoMaster
// in static/admin.src.js (Backend-Repo, read-only).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Es werden hier keine echten Netzwerk-Calls ausgefuehrt.

import Foundation

/// Fehlerfaelle des Multipart-Uploads, sauber nach Kategorie getrennt.
enum MultipartUploadError: LocalizedError, Sendable {
    /// Quelldatei nicht lesbar (verschoben, geloescht, kuerzer als gemeldet).
    case fileNotReadable(String)
    /// Der Server-Plan (Part-Anzahl/-Groesse/URLs) passt nicht zur Datei.
    case planMismatch(String)
    /// R2 lieferte kein ETag im Antwort-Header (z.B. ExposeHeaders-Problem).
    case missingETag(partNumber: Int)
    /// R2 hat einen HTTP-Fehler geliefert (Status + gekuerzter Body).
    case httpError(status: Int, body: String)
    /// Transport-Ebene (Netzwerk).
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .fileNotReadable(let m):
            return "Quelldatei nicht lesbar: \(m)"
        case .planMismatch(let m):
            return "Upload-Plan unstimmig: \(m)"
        case .missingETag(let n):
            return "R2 lieferte kein ETag für Teil \(n)."
        case .httpError(let s, let b):
            return "R2-Fehler (\(s)): \(b)"
        case .transport(let m):
            return "R2-Netzwerkfehler: \(m)"
        }
    }
}

/// PUTtet die Parts einer grossen Datei an presigned R2-URLs und sammelt die
/// ETags fuer r2-complete. Value-Type, alle Felder `let` -> Sendable.
struct MultipartUploader: Sendable {

    let session: URLSession

    /// Versuche pro Part (idempotenter PUT, gefahrlos wiederholbar).
    private static let maxAttemptsPerPart = 3
    /// Backoff nach dem 1./2./3. Fehlversuch eines Parts.
    private static let retryDelaysSeconds: [Double] = [5, 15, 45]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Vordergrund-Session (ephemeral) mit grosszuegigen Timeouts: ein
            // 256-MiB-Part darf auch ueber eine langsame Leitung in Ruhe fertig
            // werden. timeoutIntervalForRequest ist ein Idle-Timer (resettet bei
            // Daten-Aktivitaet), die Resource-Grenze deckelt nur den Extremfall.
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 600
            cfg.timeoutIntervalForResource = 60 * 60 * 24
            cfg.waitsForConnectivity = true
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Oeffentlicher Einstieg

    /// Laedt die Datei sequenziell in Parts hoch und liefert die gesammelten
    /// ETags (aufsteigend nach part_number) fuer r2-complete zurueck.
    /// - Parameters:
    ///   - fileURL: lokale Quelldatei (encodierter Master im Scratch).
    ///   - totalSizeBytes: Dateigroesse (derselbe Wert, der an r2-init ging).
    ///   - partSizeBytes: Part-Groesse aus der r2-init-Antwort (part_size).
    ///   - parts: presigned Part-URLs aus der r2-init-Antwort.
    ///   - onProgress: (abgeschlossene Bytes, Gesamtbytes, fertige Parts,
    ///     Parts gesamt) - wird nach jedem fertigen Part gerufen.
    func uploadParts(
        fileURL: URL,
        totalSizeBytes: Int64,
        partSizeBytes: Int64,
        parts: [R2InitPartDTO],
        onProgress: @escaping @Sendable (Int64, Int64, Int, Int) -> Void
    ) async throws -> [R2CompletedPart] {
        guard partSizeBytes > 0, !parts.isEmpty, totalSizeBytes > 0 else {
            throw MultipartUploadError.planMismatch("Leerer oder unbrauchbarer Part-Plan vom Server.")
        }
        // Plan gegen die Dateigroesse pruefen: Anzahl und Nummerierung der Parts
        // muessen die Datei exakt abdecken (ceil(size / part_size), Nummern 1..n).
        let ordered = parts.sorted { $0.part_number < $1.part_number }
        let expectedParts = Int((totalSizeBytes + partSizeBytes - 1) / partSizeBytes)
        guard ordered.count == expectedParts,
              ordered.first?.part_number == 1,
              ordered.last?.part_number == expectedParts else {
            throw MultipartUploadError.planMismatch(
                "Server-Plan (\(ordered.count) Parts) passt nicht zur Datei (\(expectedParts) erwartet).")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw MultipartUploadError.fileNotReadable("\(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var results: [R2CompletedPart] = []
        var completedBytes: Int64 = 0

        for part in ordered {
            // Schleifenkopf: kooperative Cancellation (remove()/App-Beenden).
            try Task.checkCancellation()

            let offset = Int64(part.part_number - 1) * partSizeBytes
            let remaining = totalSizeBytes - offset
            guard remaining > 0 else {
                throw MultipartUploadError.planMismatch("Teil \(part.part_number) liegt hinter dem Dateiende.")
            }
            let length = Int(min(partSizeBytes, remaining))
            let chunk = try Self.readChunk(handle: handle, offset: offset, length: length, fileURL: fileURL)

            let etag = try await putPart(part, body: chunk)
            results.append(R2CompletedPart(partNumber: part.part_number, etag: etag))
            completedBytes += Int64(length)
            onProgress(completedBytes, totalSizeBytes, results.count, ordered.count)
        }
        return results
    }

    // MARK: - Datei lesen (Offset-basiert, genau ein Part im Speicher)

    /// Liest `length` Bytes ab `offset` aus dem offenen FileHandle. Kuerzere
    /// Reads (Datei zwischenzeitlich geschrumpft) sind ein harter Fehler - ein
    /// unvollstaendiger Part wuerde sonst still ein kaputtes Objekt erzeugen.
    private static func readChunk(handle: FileHandle, offset: Int64, length: Int, fileURL: URL) throws -> Data {
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw MultipartUploadError.fileNotReadable(
                    "\(fileURL.lastPathComponent): Datei kürzer als erwartet (Offset \(offset)).")
            }
            return data
        } catch let error as MultipartUploadError {
            throw error
        } catch {
            throw MultipartUploadError.fileNotReadable("\(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Einzelner Part-PUT (mit Retry)

    /// PUTtet einen Part; bei transienten Fehlern bis zu maxAttemptsPerPart
    /// Versuche mit Backoff (5s/15s/45s). Liefert das ETag (ohne Anfuehrungszeichen).
    private func putPart(_ part: R2InitPartDTO, body: Data) async throws -> String {
        var attempt = 0
        while true {
            // Schleifenkopf: Abbruch vor jedem (erneuten) Versuch (Fix H7-Muster).
            try Task.checkCancellation()
            attempt += 1
            do {
                return try await putPartOnce(part, body: body)
            } catch let error as MultipartUploadError
                where Self.isTransient(error) && attempt < Self.maxAttemptsPerPart {
                // Task.sleep wirft bei Cancellation - der CancellationError wird
                // bewusst propagiert statt per try? verschluckt (Fix H7-Muster).
                let delayIndex = min(attempt - 1, Self.retryDelaysSeconds.count - 1)
                let delaySeconds = Self.retryDelaysSeconds[delayIndex]
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                // naechster Versuch
            }
        }
    }

    /// Ob ein Fehler einen Retry rechtfertigt (Netzwerk oder 429/5xx). 4xx
    /// (z.B. 403 = presigned URL abgelaufen) wird NICHT wiederholt - dann muss
    /// der Aufrufer mit frischem r2-init neu starten.
    private static func isTransient(_ error: MultipartUploadError) -> Bool {
        switch error {
        case .transport:
            return true
        case .httpError(let status, _):
            return status == 429 || (500...599).contains(status)
        case .fileNotReadable, .planMismatch, .missingETag:
            return false
        }
    }

    /// Genau ein PUT an die presigned URL. Bewusst OHNE Content-Type-Header:
    /// die Part-Signatur des Backends signiert keinen (JS-Referenz uebergibt
    /// _xhrPut(p.url, chunk, null, ...)); ein eigenmaechtiger Header koennte
    /// die Signaturpruefung brechen.
    private func putPartOnce(_ part: R2InitPartDTO, body: Data) async throws -> String {
        guard let url = URL(string: part.url) else {
            throw MultipartUploadError.planMismatch("Ungültige Part-URL (Teil \(part.part_number)).")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: req, from: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            // Ein per Task-Cancel abgebrochener URLSession-Transfer darf nicht
            // als transienter Fehler in den Retry-Backoff laufen.
            throw CancellationError()
        } catch {
            throw MultipartUploadError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MultipartUploadError.transport("Keine HTTP-Antwort von R2.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw MultipartUploadError.httpError(status: http.statusCode, body: String(text.prefix(500)))
        }
        // ETag aus dem Antwort-Header, Anfuehrungszeichen strippen (wie die
        // JS-Referenz: res.etag.replace(/"/g, "")).
        let rawETag = http.value(forHTTPHeaderField: "ETag") ?? ""
        let etag = rawETag.replacingOccurrences(of: "\"", with: "")
        guard !etag.isEmpty else {
            throw MultipartUploadError.missingETag(partNumber: part.part_number)
        }
        return etag
    }
}
