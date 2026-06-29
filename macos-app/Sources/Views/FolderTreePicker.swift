// FolderTreePicker.swift
//
// Auswahl eines Zielordners aus dem verschachtelten Ordnerbaum eines Projekts.
// Spiegelt die Backend-Struktur (video_folders mit parent_folder_id). Eine
// nil-Auswahl bedeutet "Projekt-Wurzel" (kein Ordner).
//
// Rekursion ueber konkrete View-Structs (FolderSubtree), damit Swift den Typ
// nicht unendlich aufloesen muss (kein `some View`-Selbstbezug).

import SwiftUI

struct FolderTreePicker: View {
    let nodes: [FolderNode]
    @Binding var selection: String?   // Ordner-ID, nil = Projekt-Wurzel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FolderPickRow(
                title: "Projekt-Wurzel (kein Ordner)",
                id: nil, depth: 0, videoCount: nil, isFolder: false,
                selection: $selection)
            ForEach(nodes) { node in
                FolderSubtree(node: node, depth: 0, selection: $selection)
            }
        }
    }
}

/// Ein Ordner-Teilbaum: die Zeile des Knotens, darunter rekursiv seine Kinder.
private struct FolderSubtree: View {
    let node: FolderNode
    let depth: Int
    @Binding var selection: String?

    var body: some View {
        FolderPickRow(
            title: node.name,
            id: node.id, depth: depth, videoCount: node.videoCount, isFolder: true,
            selection: $selection)
        ForEach(node.children) { child in
            FolderSubtree(node: child, depth: depth + 1, selection: $selection)
        }
    }
}

/// Eine auswaehlbare Zeile (Ordner oder Wurzel), mit Tiefen-Einrueckung.
private struct FolderPickRow: View {
    let title: String
    let id: String?
    let depth: Int
    let videoCount: Int?
    let isFolder: Bool
    @Binding var selection: String?

    var body: some View {
        Button {
            selection = id
        } label: {
            HStack(spacing: 6) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 14)
                }
                Image(systemName: isFolder ? "folder" : "tray.full")
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let c = videoCount, c > 0 {
                    Text("(\(c))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
