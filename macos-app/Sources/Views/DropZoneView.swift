// DropZoneView.swift
//
// Drag-and-Drop-Zone fuer mehrere Dateien. Erzeugt Security-Scoped Bookmarks
// (startAccessingSecurityScopedResource + Bookmark-Data speichern) und legt
// pro Datei ein QueueItem an. Setzt PLAN.md Abschnitt 10 (DropController) und
// Abschnitt 11 (Drop) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Bekannte Video-Endungen (entsprechen den vom Server akzeptierten Formaten).
/// Datei-Ebene -> nonisolated, von Hintergrund-Kontexten aus nutzbar.
private let dropZoneVideoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "mkv", "avi", "mxf", "mpg", "mpeg",
    "ts", "mts", "m2ts", "wmv", "flv", "webm", "3gp", "ogv", "dv",
]

struct DropZoneView: View {
    @Environment(QueueStore.self) private var queue
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Videos hierher ziehen")
                .font(.headline)
            Text("Mehrere Dateien gleichzeitig möglich. Ganze Ordner werden rekursiv nach Videos durchsucht. Uploads laufen auch nach dem Schließen weiter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                chooseFilesOrFolders()
            } label: {
                Label("Dateien oder Ordner wählen", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .onDrop(of: [.fileURL, .movie, .mpeg4Movie, .quickTimeMovie], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Drop-Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // QueueStore ist @MainActor -> implizit Sendable. In eine lokale Konstante
        // binden, damit die nonisolated loadItem-Completion (Sendable) sie fangen
        // darf, ohne die @MainActor-Property direkt zu referenzieren.
        let queue = queue
        var didAccept = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            didAccept = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.fileURL(from: item) else { return }
                Self.ingest(url: url, into: queue)
            }
        }
        return didAccept
    }

    /// Extrahiert eine file://-URL aus dem geladenen NSItemProvider-Item.
    /// nonisolated: wird aus der Hintergrund-Completion von loadItem aufgerufen.
    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        return nil
    }

    /// Oeffnet einen Datei-/Ordner-Dialog (Mehrfachauswahl) und legt die Auswahl an.
    private func chooseFilesOrFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        panel.message = "Videos oder Ordner mit Videos wählen"
        guard panel.runModal() == .OK else { return }
        let queue = queue
        for url in panel.urls {
            DispatchQueue.global(qos: .userInitiated).async {
                Self.ingest(url: url, into: queue)
            }
        }
    }

    /// Erzeugt Security-Scoped Bookmarks und uebergibt sie dem QueueStore.
    /// Ein Verzeichnis wird rekursiv nach Video-Dateien durchsucht.
    /// nonisolated: laeuft in der Hintergrund-Completion bzw. auf einer Background-Queue.
    private nonisolated static func ingest(url: URL, into queue: QueueStore) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let candidates: [URL] = isDir.boolValue ? videoFiles(in: url) : [url]

        for fileURL in candidates {
            guard isVideo(fileURL) else { continue }
            guard let bookmark = try? fileURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil) else { continue }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
            let name = fileURL.lastPathComponent
            Task { @MainActor in
                queue.enqueue(bookmark: bookmark, displayName: name, sourceSize: size)
            }
        }
    }

    private nonisolated static func isVideo(_ url: URL) -> Bool {
        dropZoneVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Sammelt rekursiv alle Video-Dateien unterhalb eines Verzeichnisses.
    private nonisolated static func videoFiles(in directory: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let fileURL as URL in en where isVideo(fileURL) {
            result.append(fileURL)
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
