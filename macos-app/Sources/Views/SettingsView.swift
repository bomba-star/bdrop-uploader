// SettingsView.swift
//
// Einstellungen: Admin-Token-Eingabe (Keychain), Default-Qualitaet,
// Ziel-Projekt/-Ordner-Dropdown gespeist aus listProjects.
// Setzt PLAN.md Abschnitt 10 (StatusUI, TokenStore-Anbindung) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(TokenStore.self) private var tokens

    @State private var tokenInput: String = ""
    @State private var projects: [ProjectDTO] = []
    @State private var folders: [FolderDTO] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var isChoosingExportDir = false

    var body: some View {
        Form {
            tokenSection
            qualitySection
            exportSection
            destinationSection
            videoOptionsSection
            limitsSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .task {
            await loadProjectsIfPossible()
        }
    }

    // MARK: - Token

    private var tokenSection: some View {
        Section("Admin-Token") {
            HStack {
                SecureField("Bearer-Token", text: $tokenInput)
                Button("Speichern") {
                    tokens.setAdminToken(tokenInput)
                    tokenInput = ""
                    queue.clearTokenBannerAndResume()
                    Task { await loadProjectsIfPossible() }
                }
                .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Image(systemName: tokens.hasAdminToken ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundStyle(tokens.hasAdminToken ? .green : .secondary)
                Text(tokens.hasAdminToken ? "Token hinterlegt (in der Keychain)" : "Kein Token hinterlegt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if tokens.hasAdminToken {
                    Button("Löschen", role: .destructive) {
                        tokens.clearAdminToken()
                    }
                }
            }
        }
    }

    // MARK: - Qualitaet

    private var qualitySection: some View {
        @Bindable var queue = queue
        return Section("Ausgabe") {
            Picker("Ziel", selection: $queue.defaultTarget) {
                ForEach(UploadTarget.allCases, id: \.self) { t in
                    Text(t.germanLabel).tag(t)
                }
            }
            Picker("Encode-Qualität", selection: $queue.defaultQuality) {
                ForEach(EncodeQuality.allCases, id: \.self) { q in
                    Text(q.germanLabel).tag(q)
                }
            }
            Text("Ziel: Cloudflare Stream (H.264-Master) oder 4K-HLS (adaptive Leiter, R2-Upload folgt). Qualität: Proxy 720p und Review 1080p nutzen die Hardware-Engine (schnell); Hoch 1080p und 4K-Master encodieren in Software (langsamer, bessere Qualität pro Bit). Die Stufe begrenzt auch die Auflösung bzw. die HLS-Leiter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Lokaler Export

    private var exportSection: some View {
        Section("Lokaler Export (Konvertierung ohne Upload)") {
            HStack {
                Image(systemName: "folder")
                Text(queue.exportDirectoryPath ?? "Kein Ordner gewählt")
                    .font(.subheadline)
                    .foregroundStyle(queue.exportDirectoryPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Ordner wählen") { isChoosingExportDir = true }
            }
            Text("Wird genutzt, wenn das Ziel auf \"Nur umwandeln (lokal)\" steht. Das umgewandelte Video bzw. die HLS-Leiter landet hier, ohne Upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $isChoosingExportDir, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                queue.setExportDirectory(url)
            }
        }
    }

    // MARK: - Ziel-Projekt / Ordner

    private var destinationSection: some View {
        @Bindable var queue = queue
        return Section("Ziel auf dem Server") {
            if isLoading {
                ProgressView("Projekte werden geladen ...")
            }
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Projekt", selection: Binding(
                get: { queue.defaultProjectID ?? "" },
                set: { newValue in
                    queue.defaultProjectID = newValue.isEmpty ? nil : newValue
                    queue.defaultFolderID = nil
                    Task { await loadFolders(projectID: newValue) }
                })) {
                Text("Bitte wählen").tag("")
                ForEach(projects) { project in
                    Text(project.name).tag(project.id)
                }
            }

            if folders.isEmpty {
                Text("Keine Ordner in diesem Projekt (Videos landen in der Wurzel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Zielordner")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FolderTreePicker(
                    nodes: FolderNode.buildTree(from: folders),
                    selection: $queue.defaultFolderID)
            }

            Button("Aktualisieren") {
                Task { await loadProjectsIfPossible() }
            }
        }
    }

    // MARK: - Optionen fuer neue Videos (Backend-Optionen)

    private var videoOptionsSection: some View {
        @Bindable var queue = queue
        return Section("Optionen für neue Videos") {
            Toggle("Downloads erlauben", isOn: $queue.defaultDownloadsEnabled)
            ForEach(["1080p", "4k", "original"], id: \.self) { fmt in
                Toggle(Self.formatLabel(fmt), isOn: Binding(
                    get: { queue.defaultDownloadFormats.contains(fmt) },
                    set: { isOn in
                        if isOn {
                            if !queue.defaultDownloadFormats.contains(fmt) {
                                queue.defaultDownloadFormats.append(fmt)
                            }
                        } else {
                            queue.defaultDownloadFormats.removeAll { $0 == fmt }
                        }
                    }))
                .disabled(!queue.defaultDownloadsEnabled)
                .padding(.leading, 12)
            }
            Toggle("Versionen-Switcher (Kunde sieht alle Versionen)", isOn: $queue.defaultVersionSwitcher)
            Text("Diese Optionen werden beim Anlegen neuer Videos im Backend gesetzt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Anzeigename eines Download-Formats.
    private static func formatLabel(_ fmt: String) -> String {
        switch fmt {
        case "1080p":    return "Download: 1080p"
        case "4k":       return "Download: 4K"
        case "original": return "Download: Original"
        default:         return fmt
        }
    }

    // MARK: - Limits-Hinweis

    private var limitsSection: some View {
        Section("Hinweise") {
            Label("Maximale Länge: 6 Stunden (Server-Grenze).", systemImage: "clock")
                .font(.caption)
            Label("Upload bis 32 GiB pro Datei (Server-Grenze).", systemImage: "internaldrive")
                .font(.caption)
            Label("4K-HLS: lokale Umwandlung bis 2160p vorhanden, der R2-Upload folgt.", systemImage: "4k.tv")
                .font(.caption)
        }
    }

    // MARK: - Laden

    private func loadProjectsIfPossible() async {
        guard tokens.hasAdminToken else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let client = ApiClient(tokenStore: tokens)
            projects = try await client.listProjects()
            if let pid = queue.defaultProjectID {
                await loadFolders(projectID: pid)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadFolders(projectID: String) async {
        guard !projectID.isEmpty, tokens.hasAdminToken else {
            folders = []
            return
        }
        do {
            let client = ApiClient(tokenStore: tokens)
            folders = try await client.listFolders(projectID: projectID)
        } catch {
            folders = []
            loadError = error.localizedDescription
        }
    }
}
