// QueueListView.swift
//
// Liste der Queue-Items: Name, deutsches Phase-Badge, Progressbar, Aktionen
// (Retry/Pause/Remove). Setzt PLAN.md Abschnitt 10 (StatusUI) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI
import AppKit

struct QueueListView: View {
    @Environment(QueueStore.self) private var queue

    var body: some View {
        List {
            ForEach(queue.items) { item in
                QueueRowView(item: item)
            }
        }
        .listStyle(.inset)
    }
}

/// Eine einzelne Zeile der Queue.
struct QueueRowView: View {
    @Environment(QueueStore.self) private var queue
    let item: QueueItem
    @State private var editingItem: QueueItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let tp = item.thumbnailPath, let img = NSImage(contentsOfFile: tp) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 27)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                phaseBadge
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                actions
            }

            // Progressbar in aktiven Phasen.
            if item.status.isActive && item.status != .queued {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
            }

            // Fehlertext.
            if let error = item.lastError, item.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            // Encode-Plan-Hinweis (z.B. Schnell-Remux vs. Software-H.264).
            if let plan = item.encodeSettings?.plan, item.status != .failed {
                Text(plan.germanLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .sheet(item: $editingItem) { editItem in
            ItemEditorView(item: editItem)
        }
    }

    // MARK: - Phase-Badge (deutsch)

    private var phaseBadge: some View {
        Text(item.status.germanLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch item.status {
        case .done:             return .green
        case .failed:           return .red
        case .paused:           return .gray
        case .uploading, .serverProcessing: return .blue
        case .encoding, .probing, .encoded: return .orange
        case .queued:           return .secondary
        }
    }

    // MARK: - Aktionen

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if item.status == .queued {
                Button {
                    editingItem = item
                } label: {
                    Label("Bearbeiten", systemImage: "slider.horizontal.3")
                }
                .help("Optionen bearbeiten (Ziel, Qualität, Projekt, Version)")
                .labelStyle(.iconOnly)
            }

            if item.status.isRetryable {
                Button {
                    queue.retry(item)
                } label: {
                    Label("Erneut versuchen", systemImage: "arrow.clockwise")
                }
                .help("Erneut versuchen")
                .labelStyle(.iconOnly)
            }

            if item.status.isActive && item.status != .uploading {
                Button {
                    queue.pause(item)
                } label: {
                    Label("Pausieren", systemImage: "pause.circle")
                }
                .help("Pausieren")
                .labelStyle(.iconOnly)
            }

            if item.outputPath != nil && (item.status == .done || item.target.isLocal) {
                Button {
                    queue.revealInFinder(item)
                } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                }
                .help("Im Finder zeigen")
                .labelStyle(.iconOnly)
            }

            if item.status == .done && !item.target.isLocal && item.serverVideoId != nil {
                Button {
                    Task { await queue.createAndCopyReviewLink(item) }
                } label: {
                    Label("Review-Link kopieren", systemImage: "link")
                }
                .help("Review-Link erstellen und in die Zwischenablage kopieren")
                .labelStyle(.iconOnly)
            }

            Button(role: .destructive) {
                queue.remove(item)
            } label: {
                Label("Entfernen", systemImage: "trash")
            }
            .help("Aus der Warteschlange entfernen")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
    }
}
