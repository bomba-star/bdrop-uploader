// ContentView.swift
//
// Hauptfenster: Token-Banner (bei 401), Drop-Zone, Queue-Liste.
// Setzt PLAN.md Abschnitt 10 (StatusUI) und Abschnitt 11 (Datenfluss) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI

struct ContentView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(TokenStore.self) private var tokens

    var body: some View {
        VStack(spacing: 0) {
            if queue.tokenBannerVisible {
                tokenBanner
            }

            DropZoneView()
                .padding()

            Divider()

            if queue.items.isEmpty {
                emptyState
            } else {
                QueueListView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Token-Banner (401)

    private var tokenBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Admin-Token abgelaufen oder ungültig")
                    .font(.headline)
                Text("Bitte in den Einstellungen (Cmd-,) einen gültigen Token eintragen. Uploads sind solange pausiert.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Einstellungen öffnen") {
                // Oeffnet das Standard-Settings-Fenster.
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .padding()
        .background(.orange.opacity(0.12))
    }

    // MARK: - Leerzustand

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Noch keine Videos in der Warteschlange")
                .foregroundStyle(.secondary)
            Text("Zieh ein oder mehrere Videos in den Bereich oben.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
