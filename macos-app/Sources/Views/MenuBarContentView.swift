// MenuBarContentView.swift
//
// Inhalt des Menueleisten-Extras: kompakter Queue-Status + Schnellaktionen,
// ohne das Hauptfenster zu oeffnen.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @Environment(QueueStore.self) private var queue

    var body: some View {
        let active = queue.items.filter { $0.status.isActive }.count
        let done = queue.items.filter { $0.status == .done }.count
        let failed = queue.items.filter { $0.status == .failed }.count

        VStack(alignment: .leading, spacing: 8) {
            Text("B-Drop Uploader")
                .font(.headline)
            HStack(spacing: 12) {
                Label("\(active)", systemImage: "arrow.triangle.2.circlepath")
                Label("\(done)", systemImage: "checkmark.circle")
                Label("\(failed)", systemImage: "exclamationmark.triangle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let msg = queue.lastStatusMessage {
                Divider()
                Text(msg)
                    .font(.caption)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Divider()
            Button("Fenster öffnen") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
            Button("Beenden") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
