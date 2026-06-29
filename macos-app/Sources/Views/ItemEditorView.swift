// ItemEditorView.swift
//
// Per-Item-Editor (Sheet) fuer einen wartenden Job: Titel, Ziel, Qualitaet,
// Projekt/Ordner und optional "als neue Version eines bestehenden Videos".
// Spiegelt die Backend-Struktur (Projekt-Picker + verschachtelter Ordnerbaum).
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
//
// FIX A: Lokale @State-Kopien statt direktem @Bindable-Schreiben. Aenderungen
// werden erst beim "Fertig"-Tap zurueckgeschrieben - Escape/Abbrechen verwirft.

import SwiftUI

struct ItemEditorView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(TokenStore.self) private var tokens
    @Environment(\.dismiss) private var dismiss

    // item dient nur als Datenquelle beim Initialisieren und als Schreibziel beim
    // "Fertig"-Tap. Keine Bindings (kein $item) - das verhindert Live-Commits.
    @Bindable var item: QueueItem

    // Lokale Edit-Kopien - spiegeln item-Felder beim Oeffnen, werden nur bei
    // "Fertig" zurueckgeschrieben.
    @State private var editTitle = ""
    @State private var editTarget: UploadTarget = .cfStream
    @State private var editQuality: EncodeQuality = .reviewFast
    @State private var editProjectId: String?
    @State private var editFolderId: String?
    @State private var editNewVersionId: String?
    @State private var uploadAsNewVersion = false

    @State private var projects: [ProjectDTO] = []
    @State private var folders: [FolderDTO] = []
    @State private var videos: [VideoSummaryDTO] = []
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Abbrechen") {
                    // Kein Zurueckschreiben - alle Aenderungen verwerfen.
                    dismiss()
                }
                Spacer()
                Text("Job bearbeiten")
                    .font(.headline)
                Spacer()
                Button("Fertig") {
                    // Alle edit-States zurueck ins @Model schreiben.
                    item.displayName = editTitle.isEmpty ? item.displayName : editTitle
                    item.target = editTarget
                    item.quality = editQuality
                    item.projectId = editProjectId
                    item.folderId = editFolderId
                    item.newVersionOfVideoId = uploadAsNewVersion ? editNewVersionId : nil
                    queue.persistEdits()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("Allgemein") {
                    TextField("Titel", text: $editTitle)
                    Picker("Ziel", selection: $editTarget) {
                        ForEach(UploadTarget.allCases, id: \.self) { t in
                            Text(t.germanLabel).tag(t)
                        }
                    }
                    Picker("Qualität", selection: $editQuality) {
                        ForEach(EncodeQuality.allCases, id: \.self) { q in
                            Text(q.germanLabel).tag(q)
                        }
                    }
                }

                if editTarget.isLocal {
                    Section {
                        Text("Lokaler Export: wird in den Export-Ordner gespeichert, kein Upload, keine Projekt-/Ordner-Auswahl nötig.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Ziel auf dem Server") {
                        Picker("Projekt", selection: Binding(
                            get: { editProjectId ?? "" },
                            set: { newValue in
                                editProjectId = newValue.isEmpty ? nil : newValue
                                editFolderId = nil
                                editNewVersionId = nil
                                uploadAsNewVersion = false
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
                                selection: $editFolderId)
                        }
                    }

                    Section("Version") {
                        Toggle("Als neue Version eines bestehenden Videos hochladen", isOn: $uploadAsNewVersion)
                            .disabled(editProjectId == nil)
                        if uploadAsNewVersion {
                            Picker("Bestehendes Video", selection: Binding(
                                get: { editNewVersionId ?? "" },
                                set: { editNewVersionId = $0.isEmpty ? nil : $0 })) {
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
            if !isOn { editNewVersionId = nil }
        }
        .task {
            // Zuerst alle edit-States aus item initialisieren, dann erst laden.
            editTitle = item.displayName
            editTarget = item.target
            editQuality = item.quality
            editProjectId = item.projectId
            editFolderId = item.folderId
            editNewVersionId = item.newVersionOfVideoId
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
        // Nutzt editProjectId (nicht item.projectId) - Projekt-Aenderung im Editor
        // soll sofort die passenden Ordner laden.
        guard let pid = editProjectId, tokens.hasAdminToken else { folders = []; return }
        folders = (try? await ApiClient(tokenStore: tokens).listFolders(projectID: pid)) ?? []
    }

    private func loadVideos() async {
        // Nutzt editProjectId (nicht item.projectId) - analog zu loadFolders.
        guard let pid = editProjectId, tokens.hasAdminToken else { videos = []; return }
        videos = (try? await ApiClient(tokenStore: tokens).listVideos(projectID: pid)) ?? []
    }
}
