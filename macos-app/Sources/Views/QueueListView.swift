// QueueListView.swift
//
// Liste der Queue-Items: Name, deutsches Phase-Badge, Progressbar, Aktionen
// (Retry/Pause/Remove). Setzt PLAN.md Abschnitt 10 (StatusUI) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
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
