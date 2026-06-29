// NotificationService.swift
//
// Lokale macOS-Benachrichtigungen bei fertigen oder fehlgeschlagenen Jobs.
// Sinnvoll, weil Encode/Upload lange laufen und die App im Hintergrund sein kann.
//
// Hinweis: Auf einem Linux-VPS geschrieben, auf dem Mac noch nicht gebaut.
// Unsignierte Dev-Builds zeigen Benachrichtigungen evtl. erst nach Signierung.

import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var authorized = false

    private init() {}

    /// Einmalig beim App-Start: Erlaubnis fuer Banner + Ton anfragen.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
    }

    /// Postet eine Benachrichtigung (no-op, wenn keine Erlaubnis erteilt wurde).
    func notify(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
