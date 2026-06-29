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
            Text("Mehrere Dateien gleichzeitig möglich. Uploads laufen auch nach dem Schließen weiter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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

    /// Erzeugt ein Security-Scoped Bookmark und uebergibt es dem QueueStore.
    /// nonisolated: laeuft in der Hintergrund-Completion; die Bookmark-/IO-Aufrufe
    /// sind threadsicher, der QueueStore-Zugriff hoppt am Ende selbst auf den MainActor.
    private nonisolated static func ingest(url: URL, into queue: QueueStore) {
        // Security-Scoped Zugriff oeffnen, Bookmark erzeugen, Zugriff wieder schliessen.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
        let name = url.lastPathComponent

        guard let bookmark else { return }

        Task { @MainActor in
            queue.enqueue(bookmark: bookmark, displayName: name, sourceSize: size)
        }
    }
}
