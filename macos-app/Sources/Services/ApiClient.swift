// ApiClient.swift
//
// Duenner Wrapper um die CineReview/B-Drop Admin-REST (Base https://jonasbomba.com).
// Setzt Authorization: Bearer aus dem TokenStore. Unterscheidet 401 (Token weg)
// von 429 (Rate-Limit, NICHT Token-weg). Setzt PLAN.md Abschnitt 4 + 10 um.
//
// Diese Klasse macht KEINE Background-Uploads (das ist UploadService), nur die
// kleinen JSON-Calls: Projekte/Ordner listen, Video anlegen, cf-refresh.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Es werden hier keine echten Netzwerk-Calls ausgefuehrt.

import Foundation

// MARK: - DTOs

/// Projekt aus GET /api/admin/projects. Felder `id` und `name` sind gegen einen
/// echten Call verifiziert (HTTP 200, 7 Projekte). Optionale Felder werden vom
/// Decoder stillschweigend ignoriert wenn sie in der Antwort fehlen.
struct ProjectDTO: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    // Optionale Metadaten-Felder
    var client_name: String?
    var director: String?
    var editor: String?
    var agency: String?
    var project_type: String?
    var sort_order: Int?
    var video_count: Int?
    var gallery_count: Int?
    var created_at: String?
}

/// Ordner aus GET /api/admin/projects/{id}/folders.
/// Der Endpoint liefert {"folders":[...]} - Enthuellungs-Struct FoldersEnvelope.
struct FolderDTO: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    // Optionale Felder
    var project_id: String?
    var parent_folder_id: String?
    var sort_order: Int?
    var video_count: Int?
}

/// Antwort von POST /api/admin/videos.
struct CreateVideoResponse: Decodable, Sendable {
    var id: String
}

/// Antwort von r2-stream / r2-init (enthaelt die Version-ID = Idempotenz-Klammer).
struct VersionResponse: Decodable, Sendable {
    var version_id: String?
    var id: String?
    /// Liefert die Version-ID egal unter welchem Feldnamen der Server sie schickt.
    var resolvedVersionID: String? { version_id ?? id }
}

/// Antwort von cf-refresh. Verifiziert gegen Live-Code: Server liefert
/// `{id, ready_to_stream, storage_state, status, duration_seconds}`. Das
/// Fehler-/Fertig-Signal steckt in `storage_state` (kann "error" sein),
/// nicht in `state` (PLAN.md Abschnitt 9). `state` bleibt als defensiver
/// Fallback fuer aeltere Antworten.
struct CFRefreshResponse: Decodable, Sendable {
    var storage_state: String?
    var state: String?
    var status: String?
    var ready_to_stream: Bool?

    enum Phase: Sendable { case ready, processing, error }

    var phase: Phase {
        if ready_to_stream == true { return .ready }
        let s = (storage_state ?? state ?? status ?? "").lowercased()
        if s.contains("ready") { return .ready }
        if s.contains("error") || s.contains("failed") { return .error }
        return .processing
    }
}

// MARK: - Neue DTOs (additiv)

/// Envelope fuer GET /api/admin/projects/{id}/folders.
/// Der Server liefert {"folders":[...]} als Objekt, nicht ein nacktes Array.
private struct FoldersEnvelope: Decodable {
    let folders: [FolderDTO]
}

/// Antwort von PATCH /api/admin/videos/{id}.
struct VideoDTO: Decodable, Sendable {
    var id: String
}

/// Projekt-Standardwerte aus GET /api/admin/projects/{id}/defaults.
struct ProjectDefaultsDTO: Decodable, Sendable {
    var default_downloads_enabled: Bool?
    var default_download_formats: [String]?
    var default_comments_enabled: Bool?
    var default_4k_enabled: Bool?
    var default_version_switcher_enabled: Bool?
}

/// Optionen fuer einen Review-Link (Video oder Projekt).
/// Alle Felder haben vernuenftige Defaults, sodass LinkOptions() direkt verwendbar ist.
struct LinkOptions: Sendable {
    var label: String? = nil
    var password: String? = nil
    var allowDownload: Bool = true
    var allowFeedback: Bool = true
    var theme: String = "dark"
    var playerNote: String? = nil
    var filmposter: Bool = false
    var allowVersionSwitcher: Bool = true
    var subtitlesEnabled: Bool = true
    var defaultSubtitleLang: String? = nil
    var reviewDomain: String? = nil
    var showPostproStatus: Bool = false
    var downloadFormats: [String]? = nil
}

/// Antwort von POST /api/admin/videos/{id}/links und /api/admin/projects/{id}/links.
/// Alle Felder optional (lenient) - verschiedene Server-Versionen koennen unterschiedliche Keys liefern.
struct LinkOut: Decodable, Sendable {
    var id: String?
    var token: String?
    var url: String?
}

/// Schlanke Video-Zusammenfassung fuer die Neue-Version-Auswahl.
struct VideoSummaryDTO: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var title: String
}

/// Envelope fuer GET /api/admin/projects/{id} (nur die videos-Liste interessiert hier).
private struct ProjectDetailEnvelope: Decodable {
    var videos: [VideoSummaryDTO]?
}

// MARK: - Fehler

/// API-Fehler, sauber nach Kategorie getrennt (PLAN.md Abschnitt 9).
/// Equatable, damit der QueueStore gezielt `== .unauthorized` pruefen kann.
enum ApiError: LocalizedError, Sendable, Equatable {
    case noToken
    /// 401: Token ungueltig/weg -> Banner "Token erneuern".
    case unauthorized
    /// 429: Auth-Rate-Limit (10/min). NICHT als Token-weg behandeln, Backoff + Retry.
    case rateLimited(retryAfter: TimeInterval?)
    /// 503: r2-stream-Semaphore voll -> Backoff.
    case serviceUnavailable
    case httpError(status: Int, body: String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noToken:            return "Kein Admin-Token hinterlegt. Bitte in den Einstellungen eintragen."
        case .unauthorized:       return "Der Admin-Token ist ungültig oder abgelaufen. Bitte erneuern."
        case .rateLimited:        return "Zu viele Anfragen (Rate-Limit). Wird automatisch erneut versucht."
        case .serviceUnavailable: return "Server gerade ausgelastet (Upload-Slots voll). Wird erneut versucht."
        case .httpError(let s, let b): return "Serverfehler (\(s)): \(b)"
        case .decoding(let m):    return "Antwort nicht lesbar: \(m)"
        case .transport(let m):   return "Netzwerkfehler: \(m)"
        }
    }

    /// Ob ein automatischer Backoff-Retry sinnvoll ist.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .serviceUnavailable, .transport:
            return true
        default:
            return false
        }
    }
}

// MARK: - ApiClient

/// Macht die kleinen JSON-Calls gegen die Admin-API.
struct ApiClient: Sendable {

    let tokenStore: TokenStore
    let session: URLSession

    init(tokenStore: TokenStore, session: URLSession = .shared) {
        self.tokenStore = tokenStore
        self.session = session
    }

    // MARK: - Listing (fuer UI-Dropdowns)

    /// GET /api/admin/projects
    func listProjects() async throws -> [ProjectDTO] {
        let req = try makeRequest(path: "\(AppConfig.adminPath)/projects", method: "GET")
        return try await sendDecoding(req)
    }

    /// GET /api/admin/projects/{id}/folders
    /// Hinweis: der Server liefert {"folders":[...]} als Objekt, nicht ein nacktes Array.
    func listFolders(projectID: String) async throws -> [FolderDTO] {
        let req = try makeRequest(path: "\(AppConfig.adminPath)/projects/\(projectID)/folders", method: "GET")
        let envelope: FoldersEnvelope = try await sendDecoding(req)
        return envelope.folders
    }

    /// Videos eines Projekts (fuer die Neue-Version-Auswahl).
    /// GET /api/admin/projects/{id} liefert {..., videos:[...]}.
    func listVideos(projectID: String) async throws -> [VideoSummaryDTO] {
        let req = try makeRequest(path: "\(AppConfig.adminPath)/projects/\(projectID)", method: "GET")
        let envelope: ProjectDetailEnvelope = try await sendDecoding(req)
        return envelope.videos ?? []
    }

    // MARK: - Video anlegen (PLAN.md Abschnitt 7, Schritt 1)

    /// POST /api/admin/videos
    /// - Returns: serverseitige Video-ID.
    func createVideo(name: String, projectID: String?, folderID: String?) async throws -> String {
        // Verifiziert gegen Live-Code: der Server erwartet "title", nicht "name".
        var body: [String: Any] = ["title": name]
        if let projectID { body["project_id"] = projectID }
        if let folderID { body["folder_id"] = folderID }

        var req = try makeRequest(path: "\(AppConfig.adminPath)/videos", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let resp: CreateVideoResponse = try await sendDecoding(req)
        return resp.id
    }

    // MARK: - cf-refresh-Polling (PLAN.md Abschnitt 7, Schritt 3)

    /// POST /api/admin/versions/{id}/cf-refresh (ein einzelner Aufruf).
    /// Das Backoff-Polling orchestriert der UploadService.
    func cfRefresh(versionID: String) async throws -> CFRefreshResponse {
        let req = try makeRequest(path: "\(AppConfig.adminPath)/versions/\(versionID)/cf-refresh", method: "POST")
        return try await sendDecoding(req)
    }

    // MARK: - Request-Bau fuer r2-stream (vom UploadService verwendet)

    /// Baut die URL und die Header fuer den r2-stream-Upload. Der eigentliche
    /// Body-Transfer laeuft ueber die Background-URLSession im UploadService,
    /// nicht hier.
    /// (PLAN.md Abschnitt 7: X-Upload-Filename url-encoded Pflicht etc.)
    func r2StreamRequest(
        videoID: String,
        filename: String,
        contentType: String,
        maxDurationSeconds: Int
    ) throws -> URLRequest {
        var req = try makeRequest(
            path: "\(AppConfig.adminPath)/videos/\(videoID)/versions/r2-stream",
            method: "POST")

        // X-Upload-Filename muss url-encoded sein (Pflicht laut Plan).
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename
        req.setValue(encodedName, forHTTPHeaderField: "X-Upload-Filename")
        req.setValue(contentType, forHTTPHeaderField: "X-Upload-Content-Type")
        // Auf den serverseitigen 6h-Cap deckeln (PLAN.md Abschnitt 4).
        let cappedDuration = min(maxDurationSeconds, AppConfig.maxDurationSecondsCap)
        req.setValue("\(cappedDuration)", forHTTPHeaderField: "X-Upload-Max-Duration")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return req
    }

    // MARK: - cf-refresh / version-id aus einer r2-stream-Antwort lesen

    /// Decodiert die Server-Antwort eines abgeschlossenen r2-stream-Uploads in
    /// die Version-ID. Wird vom UploadService nach Transfer-Abschluss benutzt.
    func parseVersionID(from data: Data) throws -> String {
        guard let resp = try? JSONDecoder().decode(VersionResponse.self, from: data),
              let vid = resp.resolvedVersionID else {
            throw ApiError.decoding("Keine version_id in der r2-stream-Antwort.")
        }
        return vid
    }

    // MARK: - presigned Multipart (Fallback, TODO-Stub)

    /// TODO(Fallback): POST /api/admin/videos/{id}/versions/r2-init.
    /// Nur fuer Dateien ueber ~10 GB. presigned Part-URLs haben TTL 12h
    /// (PLAN.md Abschnitt 7). In dieser App-Version nicht implementiert.
    func r2Init(videoID: String, sizeBytes: Int64, filename: String) async throws -> Never {
        throw ApiError.transport("r2-init Multipart-Fallback ist in dieser App-Version noch nicht implementiert (siehe PLAN.md Abschnitt 7).")
    }

    /// TODO(Fallback): POST /api/admin/videos/{id}/versions/r2-complete.
    func r2Complete(videoID: String, versionID: String) async throws -> Never {
        throw ApiError.transport("r2-complete Multipart-Fallback ist in dieser App-Version noch nicht implementiert (siehe PLAN.md Abschnitt 7).")
    }

    // MARK: - Ordner anlegen

    /// POST /api/admin/folders
    /// - Parameter parentFolderID: optionaler Eltern-Ordner; wird weggelassen wenn nil.
    /// - Returns: der neu angelegte FolderDTO.
    func createFolder(projectID: String, name: String, parentFolderID: String?) async throws -> FolderDTO {
        var body: [String: Any] = ["project_id": projectID, "name": name]
        if let pid = parentFolderID { body["parent_folder_id"] = pid }
        var req = try makeRequest(path: "\(AppConfig.adminPath)/folders", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await sendDecoding(req)
    }

    // MARK: - Projekt-Defaults

    /// GET /api/admin/projects/{id}/defaults
    func getProjectDefaults(projectID: String) async throws -> ProjectDefaultsDTO {
        let req = try makeRequest(path: "\(AppConfig.adminPath)/projects/\(projectID)/defaults", method: "GET")
        return try await sendDecoding(req)
    }

    // MARK: - Video aktualisieren

    /// PATCH /api/admin/videos/{id}
    /// Nur nicht-nil Felder landen im Request-Body (snake_case Keys).
    func updateVideo(
        videoID: String,
        title: String? = nil,
        description: String? = nil,
        downloadsEnabled: Bool? = nil,
        downloadFormats: [String]? = nil,
        versionSwitcherEnabled: Bool? = nil
    ) async throws -> VideoDTO {
        var body: [String: Any] = [:]
        if let v = title { body["title"] = v }
        if let v = description { body["description"] = v }
        if let v = downloadsEnabled { body["downloads_enabled"] = v }
        if let v = downloadFormats { body["download_formats"] = v }
        if let v = versionSwitcherEnabled { body["version_switcher_enabled"] = v }
        var req = try makeRequest(path: "\(AppConfig.adminPath)/videos/\(videoID)", method: "PATCH")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await sendDecoding(req)
    }

    // MARK: - Review-Links anlegen

    /// POST /api/admin/videos/{id}/links
    func createVideoLink(videoID: String, options: LinkOptions) async throws -> LinkOut {
        let body = linkOptionsBody(options)
        var req = try makeRequest(path: "\(AppConfig.adminPath)/videos/\(videoID)/links", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await sendDecoding(req)
    }

    /// POST /api/admin/projects/{id}/links
    func createProjectLink(projectID: String, options: LinkOptions) async throws -> LinkOut {
        let body = linkOptionsBody(options)
        var req = try makeRequest(path: "\(AppConfig.adminPath)/projects/\(projectID)/links", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await sendDecoding(req)
    }

    /// Wandelt LinkOptions in ein [String:Any]-Dictionary (snake_case Keys, nil-Felder weggelassen).
    /// Bool-Felder werden immer gesetzt, auch wenn sie dem Default entsprechen.
    private func linkOptionsBody(_ options: LinkOptions) -> [String: Any] {
        var body: [String: Any] = [
            "allow_download": options.allowDownload,
            "allow_feedback": options.allowFeedback,
            "theme": options.theme,
            "filmposter": options.filmposter,
            "allow_version_switcher": options.allowVersionSwitcher,
            "subtitles_enabled": options.subtitlesEnabled,
            "show_postpro_status": options.showPostproStatus,
        ]
        if let v = options.label { body["label"] = v }
        if let v = options.password { body["password"] = v }
        if let v = options.playerNote { body["player_note"] = v }
        if let v = options.defaultSubtitleLang { body["default_subtitle_lang"] = v }
        if let v = options.reviewDomain { body["review_domain"] = v }
        if let v = options.downloadFormats { body["download_formats"] = v }
        return body
    }

    // MARK: - Intern

    /// Baut einen Request inkl. Bearer-Header. Wirft .noToken, wenn keiner gesetzt ist.
    func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let token = tokenStore.adminToken(), !token.isEmpty else {
            throw ApiError.noToken
        }
        guard let url = URL(string: path, relativeTo: AppConfig.baseURL) else {
            throw ApiError.transport("Ungültige URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("BDropUploader/0.1", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Sendet einen Request und decodiert die JSON-Antwort, mit sauberer
    /// Status-Klassifikation (401/429/503/...).
    private func sendDecoding<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, status, headers) = try await send(request)
        try Self.classify(status: status, headers: headers, body: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ApiError.decoding("\(error.localizedDescription) | \(body.prefix(200))")
        }
    }

    /// Roher Send mit Status und Headern.
    private func send(_ request: URLRequest) async throws -> (Data, Int, [AnyHashable: Any]) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiError.transport("Keine HTTP-Antwort.")
            }
            return (data, http.statusCode, http.allHeaderFields)
        } catch let error as ApiError {
            throw error
        } catch {
            throw ApiError.transport(error.localizedDescription)
        }
    }

    /// Wandelt HTTP-Statuscodes in die getrennten ApiError-Faelle (PLAN.md Abschnitt 9).
    static func classify(status: Int, headers: [AnyHashable: Any], body: Data) throws {
        switch status {
        case 200..<300:
            return
        case 401:
            throw ApiError.unauthorized
        case 429:
            // Retry-After-Header beruecksichtigen, falls vorhanden.
            let retryAfter = (headers["Retry-After"] as? String).flatMap(TimeInterval.init)
            throw ApiError.rateLimited(retryAfter: retryAfter)
        case 503:
            throw ApiError.serviceUnavailable
        default:
            let text = String(data: body, encoding: .utf8) ?? ""
            throw ApiError.httpError(status: status, body: String(text.prefix(300)))
        }
    }
}
