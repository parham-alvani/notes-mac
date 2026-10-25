import AppKit
import DaftarCore
import Foundation
import UserNotifications

/// Meeting alerts and the morning task digest, through Notification Center.
///
/// Both are planned ahead as notification requests, so they arrive while the
/// app is closed too. They are planned again whenever the vault changes: a
/// week note written by the phone, a task ticked.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Nil outside an app bundle (`swift run`), where asking for the center
    /// aborts the process.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    private var authorized = false

    private static let meetingPrefix = "meeting."
    private static let digestId = "digest"
    nonisolated private static let joinAction = "join"

    func start() {
        guard let center else { return }
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meeting", actions: [join], intentIdentifiers: []),
        ])
        Task {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Replaces every pending request with the ones the vault calls for now.
    func plan(store: VaultStore) async {
        guard let center else { return }
        if !authorized { authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
        guard authorized else { return }
        let settings = store.settings
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.hasPrefix(Self.meetingPrefix) || $0 == Self.digestId
        })

        if settings.meetingAlerts {
            let now = Date()
            let lead = TimeInterval(settings.meetingLead * 60)
            let meetings = store.calendarDays(from: .today(), count: 3).flatMap(\.meetings)
                .filter { ($0.start ?? .distantPast).addingTimeInterval(-lead) > now }
                .prefix(40)
            for meeting in meetings {
                guard let start = meeting.start else { continue }
                let content = UNMutableNotificationContent()
                content.title = meeting.title + (meeting.tentative ? " (maybe)" : "")
                let time = start.formatted(date: .omitted, time: .shortened)
                content.body = settings.meetingLead > 0 ? "In \(settings.meetingLead) minutes, at \(time)" : "Now, at \(time)"
                if let overlaps = meeting.overlaps { content.body += ". Overlaps \(overlaps)" }
                content.sound = .default
                if let join = meeting.join {
                    content.categoryIdentifier = "meeting"
                    content.userInfo = ["join": join.absoluteString]
                }
                let at = start.addingTimeInterval(-lead)
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at), repeats: false)
                try? await center.add(UNNotificationRequest(identifier: Self.meetingPrefix + meeting.id, content: content, trigger: trigger))
            }
        }

        if settings.taskDigest, let (at, day) = nextDigest(minutes: settings.digestTime) {
            let groups = store.taskGroups(today: day, days: 0)
            let due = groups.today
            guard !due.isEmpty || !groups.overdue.isEmpty else { return }
            let content = UNMutableNotificationContent()
            content.title = due.isEmpty ? "Nothing due today" : "\(due.count) due today"
            var lines = due.prefix(5).map { "• " + TaskRow.plain($0.task.text) }
            if due.count > 5 { lines.append("and \(due.count - 5) more") }
            if !groups.overdue.isEmpty { lines.append("\(groups.overdue.count) overdue") }
            content.body = lines.joined(separator: "\n")
            content.userInfo = ["open": "today"]
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.digestId, content: content, trigger: trigger))
        }
    }

    /// The next time the digest is due, and the day it is about.
    private func nextDigest(minutes: Int) -> (Date, Day)? {
        let calendar = Calendar.current
        let now = Date()
        var at = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now)!
        if at <= now { at = calendar.date(byAdding: .day, value: 1, to: at)! }
        return (at, Day(date: at, in: .current))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let join = info["join"] as? String, let url = URL(string: join),
            response.actionIdentifier == Self.joinAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        } else if info["open"] as? String == "today", let url = URL(string: "daftar://open?path=today") {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }
}
