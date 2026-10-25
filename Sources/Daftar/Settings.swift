import AppKit
import Foundation
import Observation

/// The app's settings, in `UserDefaults`.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var vaultPath: String? {
        didSet { defaults.set(vaultPath, forKey: "vaultPath") }
    }

    /// Minutes between commit-pull-push runs; 0 is off. Off at first: while
    /// Obsidian's git plugin still syncs the same folder, two syncs would race.
    var syncInterval: Int {
        didSet { defaults.set(syncInterval, forKey: "syncInterval") }
    }

    var meetingAlerts: Bool {
        didSet { defaults.set(meetingAlerts, forKey: "meetingAlerts") }
    }

    /// How long before a meeting it is announced.
    var meetingLead: Int {
        didSet { defaults.set(meetingLead, forKey: "meetingLead") }
    }

    var taskDigest: Bool {
        didSet { defaults.set(taskDigest, forKey: "taskDigest") }
    }

    /// Minutes after midnight.
    var digestTime: Int {
        didSet { defaults.set(digestTime, forKey: "digestTime") }
    }

    var textSize: Int {
        didSet { defaults.set(textSize, forKey: "textSize") }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// Light is Daftar's Daylight palette, dark is naz. The reader follows the
    /// window, so this one setting changes both.
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    /// The Dock icon counts the tasks due today and overdue.
    var dockBadge: Bool {
        didSet { defaults.set(dockBadge, forKey: "dockBadge") }
    }

    func applyAppearance() {
        NSApp?.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private init() {
        vaultPath = defaults.string(forKey: "vaultPath")
        syncInterval = defaults.object(forKey: "syncInterval") as? Int ?? 0
        meetingAlerts = defaults.object(forKey: "meetingAlerts") as? Bool ?? true
        meetingLead = defaults.object(forKey: "meetingLead") as? Int ?? 5
        taskDigest = defaults.object(forKey: "taskDigest") as? Bool ?? true
        digestTime = defaults.object(forKey: "digestTime") as? Int ?? 9 * 60
        textSize = defaults.object(forKey: "textSize") as? Int ?? 15
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        dockBadge = defaults.object(forKey: "dockBadge") as? Bool ?? true
    }
}
