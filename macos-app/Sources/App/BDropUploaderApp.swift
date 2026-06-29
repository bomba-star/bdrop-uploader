// BDropUploaderApp.swift
//
// App-Entry. @main, App-Struct, WindowGroup, SwiftData-Container.
// Verdrahtet TokenStore -> ApiClient -> UploadService -> QueueStore.
// Setzt PLAN.md Abschnitt 10 (Komponenten) und Abschnitt 11 (Datenfluss) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI
import SwiftData

@main
struct BDropUploaderApp: App {

    /// SwiftData-Container fuer die QueueItem-Persistenz.
    private let modelContainer: ModelContainer

    /// Geteilte Dienste. @State, damit sie ueber die App-Lebensdauer leben.
    @State private var tokenStore: TokenStore
    @State private var queueStore: QueueStore

    init() {
        // 1) SwiftData-Container.
        let schema = Schema([QueueItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData-Container konnte nicht erstellt werden: \(error)")
        }
        self.modelContainer = container

        // 2) Dienste verdrahten.
        let tokens = TokenStore()
        let api = ApiClient(tokenStore: tokens)
        let uploads = UploadService(apiClient: api)
        let store = QueueStore(
            modelContext: container.mainContext,
            tokenStore: tokens,
            apiClient: api,
            uploadService: uploads)

        _tokenStore = State(initialValue: tokens)
        _queueStore = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(queueStore)
                .environment(tokenStore)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    // Crash-Recovery einmalig beim Start (PLAN.md Abschnitt 8).
                    await queueStore.performCrashRecovery()
                }
        }
        .modelContainer(modelContainer)
        .windowResizability(.contentSize)
        .commands {
            // Standard-Menues; eigene Befehle koennen hier ergaenzt werden.
            CommandGroup(replacing: .newItem) { }
        }

        // Einstellungen ueber das Standard-macOS-Settings-Fenster (Cmd-,).
        Settings {
            SettingsView()
                .environment(queueStore)
                .environment(tokenStore)
        }

        // TODO(optional): MenuBarExtra fuer schnellen Queue-Status ohne Hauptfenster.
        // MenuBarExtra("B-Drop", systemImage: "arrow.up.circle") {
        //     MenuBarContentView().environment(queueStore)
        // }
        // .menuBarExtraStyle(.window)
    }
}
