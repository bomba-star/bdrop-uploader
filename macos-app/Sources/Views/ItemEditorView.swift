// ItemEditorView.swift
//
// Per-Item-Editor (Sheet) fuer einen wartenden Job: Titel, Ziel, Qualitaet,
// Projekt/Ordner und optional "als neue Version eines bestehenden Videos".
// Spiegelt die Backend-Struktur (Projekt-Picker + verschachtelter Ordnerbaum).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI

struct ItemEditorView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(TokenStore.self) private var tokens
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: QueueItem

    @State private var projects: [ProjectDTO] = []
    @State private var folders: [FolderDTO] = []
    @State private var videos: [VideoSummaryDTO] = []
    @State private var uploadAsNewVersion = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Job bearbeiten")
                    .font(.headline)
                Spacer()
                Button("Fertig") {
                    queue.persistEdits()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("Allgemein") {
                    TextField("Titel", text: $item.displayName)
                    Picker("Ziel", selection: $item.target) {
                        ForEach(UploadTarget.allCases, id: \.self) { t in
                            Text(t.germanLabel).tag(t)
                        }
                    }
                    Picker("Qualität", selection: $item.quality) {
                        ForEach(EncodeQuality.allCases, id: \.self) { q in
                            Text(q.germanLabel).tag(q)
                        }
                    }
                }

                if item.target.isLocal {
                    Section {
                        Text("Lokaler Export: wird in den Export-Ordner gespeichert, kein Upload, keine Projekt-/Ordner-Auswahl nötig.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Ziel auf dem Server") {
                        Picker("Projekt", selection: Binding(
                            get: { item.projectId ?? "" },
                            set: { newValue in
                                item.projectId = newValue.isEmpty ? nil : newValue
                                item.folderId = nil
                                item.newVersionOfVideoId = nil
                                Task { await loadFolders(); await loadVideos() }
                            })) {
                            Text("Bitte wählen").tag("")
                            ForEach(projects) { p in Text(p.name).tag(p.id) }
                        }
                        if !folders.isEmpty {
                            Text("Zielordner")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            FolderTreePicker(
                                nodes: FolderNode.buildTree(from: folders),
                                selection: $item.folderId)
                        }
                    }

                    Section("Version") {
                        Toggle("Als neue Version eines bestehenden Videos hochladen", isOn: $uploadAsNewVersion)
                            .disabled(item.projectId == nil)
                        if uploadAsNewVersion {
                            Picker("Bestehendes Video", selection: Binding(
                                get: { item.newVersionOfVideoId ?? "" },
                                set: { item.newVersionOfVideoId = $0.isEmpty ? nil : $0 })) {
                                Text("Bitte wählen").tag("")
                                ForEach(videos) { v in Text(v.title).tag(v.id) }
                            }
                            Text("Lädt eine neue Version zum gewählten Video hoch. Projekt/Ordner/Optionen des Videos bleiben unverändert.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 540)
        .onChange(of: uploadAsNewVersion) { _, isOn in
            if !isOn { item.newVersionOfVideoId = nil }
        }
        .task {
            uploadAsNewVersion = item.newVersionOfVideoId != nil
            await loadProjects()
            await loadFolders()
            await loadVideos()
        }
    }

    // MARK: - Laden

    private func loadProjects() async {
        guard tokens.hasAdminToken else { return }
        do {
            projects = try await ApiClient(tokenStore: tokens).listProjects()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadFolders() async {
        guard let pid = item.projectId, tokens.hasAdminToken else { folders = []; return }
        folders = (try? await ApiClient(tokenStore: tokens).listFolders(projectID: pid)) ?? []
    }

    private func loadVideos() async {
        guard let pid = item.projectId, tokens.hasAdminToken else { videos = []; return }
        videos = (try? await ApiClient(tokenStore: tokens).listVideos(projectID: pid)) ?? []
    }
}
