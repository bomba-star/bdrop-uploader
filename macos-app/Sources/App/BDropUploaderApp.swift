// BDropUploaderApp.swift
//
// App-Entry. @main, App-Struct, WindowGroup, SwiftData-Container.
// Verdrahtet TokenStore -> ApiClient -> UploadService -> QueueStore.
// Setzt PLAN.md Abschnitt 10 (Komponenten) und Abschnitt 11 (Datenfluss) um.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.

import SwiftUI
import SwiftData
import AppKit

@main
struct BDropUploaderApp: App {

    /// SwiftData-Container fuer die QueueItem-Persistenz.
    private let modelContainer: ModelContainer

    /// AppKit-Delegate fuer den Beenden-Hook (Cmd-Q waehrend eines Encodes, Fix H12).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

        // Dem Beenden-Hook den Store bekannt machen (Fix H12). Minimal-invasiv
        // ueber eine statische weak-Referenz; der Store lebt die App-Lebensdauer.
        AppDelegate.queueStore = store
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(queueStore)
                .environment(tokenStore)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    // Crash-Recovery einmalig und ZUERST (PLAN.md Abschnitt 8):
                    // der Notification-Dialog (requestAuthorization) kann beim
                    // Erststart beliebig lange offen stehen und darf die
                    // Zustands-Entscheidung ueber .uploading-Items nicht
                    // verzoegern (Fix H4).
                    await queueStore.performCrashRecovery()
                    await NotificationService.shared.requestAuthorization()
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

        // Menueleisten-Extra fuer schnellen Queue-Status ohne Hauptfenster.
        MenuBarExtra("B-Drop", systemImage: "arrow.up.circle") {
            MenuBarContentView()
                .environment(queueStore)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate (Beenden-Hook, Fix H12)

/// Faengt das App-Beenden ab, wenn noch ein Encode laeuft: ohne diesen Hook
/// liefe ffmpeg als Waisenprozess weiter und ein Neustart startete (via
/// Crash-Recovery) einen parallelen Zweit-Encode derselben Quelle.
/// Warnt ausserdem bei einem laufenden Multipart-Upload (grosse Dateien):
/// der laeuft in einer Vordergrund-Session und wird beim Beenden abgebrochen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Wird beim App-Start von BDropUploaderApp.init gesetzt. weak, damit der
    /// Delegate keine eigene Lebensdauer-Verantwortung uebernimmt (der Store
    /// haengt als @State an der App-Struktur).
    static weak var queueStore: QueueStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.queueStore else { return .terminateNow }
        let encodeActive = store.hasActiveEncode
        // Multipart und R2-HLS laufen beide in Vordergrund-Sessions und sterben
        // mit der App; beide brauchen dieselbe Warnung.
        let uploadActive = store.hasActiveMultipartUpload || store.hasActiveR2HLSUpload
        guard encodeActive || uploadActive else {
            return .terminateNow
        }

        let alert = NSAlert()
        if encodeActive && uploadActive {
            alert.messageText = "Encode und großer Upload laufen noch"
            alert.informativeText = "Ein Encode und ein großer Upload laufen noch und werden beim Beenden abgebrochen."
        } else if uploadActive {
            alert.messageText = "Großer Upload läuft noch"
            alert.informativeText = "Ein großer Upload läuft noch und wird beim Beenden abgebrochen."
        } else {
            alert.messageText = "Encode läuft noch"
            alert.informativeText = "Ein Encode läuft noch. Beenden bricht ihn ab; Uploads laufen im Hintergrund weiter."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // Erst den ffmpeg-Prozess und laufende Vordergrund-Uploads (R2-HLS +
        // Multipart) abbrechen, dann das Beenden freigeben. terminateLater statt
        // terminateNow, weil cancel() actor-isoliert ist und vor dem
        // Prozess-Ende gelaufen sein muss.
        Task { @MainActor in
            await store.cancelActiveEncodeForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
