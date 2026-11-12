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

    /// One alert the vault calls for, as plain values, so a plan can be
    /// compared with the one before.
    struct Planned: Equatable {
        var id: String
        var title: String
        var body: String
        var category = ""
        var userInfo: [String: String] = [:]
        /// Meetings ring; the digest comes in silence.
        var sound = false
        var at: DateComponents

        var request: UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            if !category.isEmpty { content.categoryIdentifier = category }
            content.userInfo = userInfo
            return UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: false))
        }
    }

    /// What was asked of Notification Center last, kept until the app quits.
    private var planned: [Planned]?

    /// The meeting alerts and the digest the vault calls for now.
    static func plan(store: VaultStore, now: Date = Date()) -> [Planned] {
        let settings = store.settings
        var out: [Planned] = []
        let minute: (Date) -> DateComponents = { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        if settings.meetingAlerts {
            let lead = TimeInterval(settings.meetingLead * 60)
            let meetings = store.calendarDays(from: Day(date: now, in: .current), count: 3).flatMap(\.meetings)
                .filter { ($0.start ?? .distantPast).addingTimeInterval(-lead) > now }
                .prefix(40)
            for meeting in meetings {
                guard let start = meeting.start else { continue }
                let time = start.formatted(date: .omitted, time: .shortened)
                var body = settings.meetingLead > 0 ? "In \(settings.meetingLead) minutes, at \(time)" : "Now, at \(time)"
                if let overlaps = meeting.overlaps { body += ". Overlaps \(overlaps)" }
                out.append(Planned(
                    id: meetingPrefix + meeting.id, title: meeting.title + (meeting.tentative ? " (maybe)" : ""), body: body,
                    category: meeting.join == nil ? "" : "meeting", userInfo: meeting.join.map { ["join": $0.absoluteString] } ?? [:],
                    sound: true, at: minute(start.addingTimeInterval(-lead))))
            }
        }
        if settings.taskDigest {
            let (at, day) = nextDigest(minutes: settings.digestTime, now: now)
            let groups = store.taskGroups(today: day, days: 0)
            let due = groups.today
            if !due.isEmpty || !groups.overdue.isEmpty {
                var lines = due.prefix(5).map { "• " + TaskRow.plain($0.task.text) }
                if due.count > 5 { lines.append("and \(due.count - 5) more") }
                if !groups.overdue.isEmpty { lines.append("\(groups.overdue.count) overdue") }
                out.append(Planned(
                    id: digestId, title: due.isEmpty ? "Nothing due today" : "\(due.count) due today", body: lines.joined(separator: "\n"),
                    userInfo: ["open": "today"], at: minute(at)))
            }
        }
        return out
    }

    /// Replaces every pending request with the ones the vault calls for now,
    /// unless they are the ones already pending: the vault changes at every
    /// save, its alerts seldom, and each request is a round trip to the
    /// notification server, which writes its store.
    func plan(store: VaultStore) async {
        guard let center else { return }
        if !authorized { authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
        guard authorized else { return }
        let wanted = Self.plan(store: store)
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter {
            $0.hasPrefix(Self.meetingPrefix) || $0 == Self.digestId
        }
        if wanted == planned, Set(pending) == Set(wanted.map(\.id)) { return }
        planned = nil
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for request in wanted { try? await center.add(request.request) }
        planned = wanted
    }

    /// The next time the digest is due, and the day it is about.
    static func nextDigest(minutes: Int, now: Date = Date()) -> (Date, Day) {
        let calendar = Calendar.current
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
        if let join = info["join"] as? String, let url = URL(string: join), Vault.leavesTheApp(url),
            response.actionIdentifier == Self.joinAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        } else if info["open"] as? String == "today", let url = URL(string: "daftar://open?path=today") {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }
}
