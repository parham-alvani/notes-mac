import AppKit
import DaftarCore
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import DaftarUI

/// What VoiceOver gets from the app's views: each view is drawn in an
/// off-screen window and its accessibility tree read through AppKit's
/// `NSAccessibility` protocol, as an assistive app reads it. Every button
/// must have a name, and the rows say in words what their colours say.
@MainActor
@Suite(.serialized) struct AccessibilityTests {
    let root: URL
    let store: VaultStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "daftar-a11y-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Work"), withIntermediateDirectories: true)
        let today = Day.today()
        let late = today.adding(days: -3)
        try "# Plan\n\n## Kit\n- [ ] Call Sara ⏫ 📅 \(today)\n- [/] Build the shelf\n- [ ] Pay rent 📅 \(late)\n\nSee [[Notes]].\n"
            .write(to: root.appending(path: "Work/Plan.md"), atomically: true, encoding: .utf8)
        try "# Notes\n\n## One\n\nText.\n\n### Two\n\nMore. #project/kit\n".write(to: root.appending(path: "Notes.md"), atomically: true, encoding: .utf8)
        store = VaultStore(settings: AppSettings(url: root.appending(path: "config/config.toml")), openVault: false)
        store.openSynchronously(root)
    }

    /// One element of the tree: its role and the name VoiceOver says.
    struct Element {
        var role: String
        var name: String
        var value: String
    }

    /// [view] in a window off screen, and every element of its tree.
    func elements<V: View>(_ view: V, size: CGSize = CGSize(width: 900, height: 700)) async throws -> [Element] {
        // What an assistive app sets when it starts: SwiftUI builds its
        // accessibility tree only then.
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view.environment(store))
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        // SwiftUI builds its accessibility tree when it is first asked for it.
        _ = NSApplication.shared
        _ = hosting.accessibilityChildren()
        _ = window.accessibilityChildren()
        try await Task.sleep(for: .milliseconds(800))
        hosting.layoutSubtreeIfNeeded()
        var out: [Element] = []
        func walk(_ node: Any, depth: Int) {
            // Read as an assistive app reads: by the protocol's getters,
            // or the AX attributes of an element that has only those.
            guard depth < 40, let element = node as? NSObject else { return }
            func get(_ getter: String, _ attribute: NSAccessibility.Attribute) -> Any? {
                let selector = NSSelectorFromString(getter)
                if element.responds(to: selector), let found = element.perform(selector)?.takeUnretainedValue(), (found as? String)?.isEmpty != true { return found }
                return element.accessibilityAttributeNames().contains(attribute) ? element.accessibilityAttributeValue(attribute) : nil
            }
            // A title can come as attributed text.
            func text(_ any: Any?) -> String { any as? String ?? (any as? NSAttributedString)?.string ?? "" }
            let label = text(get("accessibilityLabel", .description))
            let title = text(get("accessibilityTitle", .title))
            out.append(Element(role: text(get("accessibilityRole", .role)), name: label.isEmpty ? title : label, value: text(get("accessibilityValue", .value))))
            // A scroll bar's arrows and page areas are AppKit's, not the app's.
            guard out.last?.role != NSAccessibility.Role.scrollBar.rawValue else { return }
            for child in get("accessibilityChildren", .children) as? [Any] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return out
    }

    /// Every button has a name: an icon alone says nothing to VoiceOver.
    func expectNamedButtons(_ elements: [Element], sourceLocation: SourceLocation = #_sourceLocation) {
        let unnamed = elements.filter { [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.menuButton.rawValue].contains($0.role) && $0.name.isEmpty }
        #expect(unnamed.isEmpty, "buttons with no name: \(unnamed.count)", sourceLocation: sourceLocation)
    }

    @Test func todaySaysEachTaskInWords() async throws {
        let found = try await elements(TodayView(model: WindowModel()))
        #expect(found.count > 5)
        expectNamedButtons(found)
        let names = found.map(\.name)
        #expect(names.contains { $0.hasPrefix("Call Sara, open, due today, high priority, in Plan › Kit") })
        #expect(names.contains { $0.hasPrefix("Pay rent, open, due ") && $0.contains("overdue") })
        // The square is a toggle with its task, not an unnamed image.
        #expect(found.contains { $0.name == "Call Sara" && $0.value == "open" })
    }

    @Test func boardCardsAreElementsWithTheirTask() async throws {
        let found = try await elements(BoardView(model: WindowModel()), size: CGSize(width: 1400, height: 800))
        expectNamedButtons(found)
        let names = found.map(\.name)
        #expect(names.contains { $0.hasPrefix("Build the shelf, in progress") })
        #expect(names.contains { $0.hasPrefix("To do, ") || $0.hasPrefix("To Do, ") || $0.contains(", 2 tasks") })
    }

    @Test func theSidebarSaysWhatColoursAndIconsSay() async throws {
        let model = WindowModel()
        let found = try await elements(FilesList(model: model), size: CGSize(width: 320, height: 900))
        expectNamedButtons(found)
        #expect(found.contains { $0.name == "Plan" || $0.name == "Notes" })
        #expect(found.contains { $0.value.hasPrefix("Note") || $0.value.hasPrefix("Folder") })
    }

    @Test func theInspectorOutlineSaysTheLevel() async throws {
        let model = WindowModel()
        model.open("Notes.md", store: store)
        let found = try await elements(InspectorView(model: model), size: CGSize(width: 320, height: 900))
        expectNamedButtons(found)
        #expect(found.contains { $0.name == "Heading level 2, One" })
        #expect(found.contains { $0.name == "Heading level 3, Two" })
    }

    @Test func aSplitPaneHasANamedCloseButton() async throws {
        let model = WindowModel()
        model.open("Notes.md", store: store)
        model.toggleSplit()
        let found = try await elements(Breadcrumb(path: "Work/Plan.md", model: model, onClose: {}), size: CGSize(width: 700, height: 40))
        expectNamedButtons(found)
        #expect(found.contains { $0.name == "Close Pane" })
        #expect(found.contains { $0.name == "Folder Work" })
    }

    @Test func theHomePageNamesItsControlsAndHidesThePicture() async throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".obsidian/plugins/beautitab"), withIntermediateDirectories: true)
        try #"{"greetingText": "Hello, Tester.", "showBookmarks": true}"#
            .write(to: root.appending(path: ".obsidian/plugins/beautitab/data.json"), atomically: true, encoding: .utf8)
        store.toggleBookmark("Notes.md")
        let picture = root.appending(path: "home.png")
        try HomeViewTests.picture(at: picture, red: 0.2, green: 0.3, blue: 0.5, width: 64, height: 40)
        store.settings.homeImage = picture.path
        let model = WindowModel()
        model.open("Work/Plan.md", store: store)
        model.focused.request = nil
        let found = try await elements(HomeView(model: model, pane: model.focused))
        expectNamedButtons(found)
        let names = found.map(\.name)
        // The time, the date and the greeting are one text.
        #expect(found.contains { ($0.name + $0.value).contains("Hello, Tester.") })
        #expect(names.contains("Find a note"))
        #expect(names.contains("Plan, in Work"))
        #expect(names.contains("Notes"))
        // The picture and the icons are decoration.
        #expect(!found.contains { $0.role == NSAccessibility.Role.image.rawValue }, "\(found.filter { $0.role == NSAccessibility.Role.image.rawValue })")
    }

    @Test func theTaskSheetNamesItsFieldsAndSaysTheChoice() async throws {
        let found = try await elements(TaskEditSheet(task: TaskRef(path: "Work/Plan.md", line: 3)))
        expectNamedButtons(found)
        #expect(found.contains { $0.name == "Task" })
        #expect(found.contains { $0.name == "Repeat Rules" })
        #expect(found.contains { $0.name == "Due date" })
    }

    @Test func theMoveSheetListsFoldersAsButtons() async throws {
        let found = try await elements(FileActionSheet(action: .move("Notes.md"), model: WindowModel()))
        expectNamedButtons(found)
        #expect(found.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "Work" })
    }

    @Test func replaceInVaultNamesItsFieldsAndBoxes() async throws {
        let found = try await elements(VaultReplaceSheet(target: ReplaceTarget(folder: "")))
        expectNamedButtons(found)
        #expect(found.contains { $0.name == "Find" })
        #expect(found.contains { $0.name == "Replace with" })
    }

    @Test func quickCaptureAndTheIconPickerHaveNoUnnamedButtons() async throws {
        let capture = try await elements(CaptureView(model: CaptureModel(), add: { _ in }, close: {}), size: CGSize(width: 560, height: 140))
        expectNamedButtons(capture)
        #expect(capture.contains { $0.name == "Add as Task" })
        let icons = try await elements(IconPicker(target: IconTarget(path: "Notes.md", folder: false)))
        expectNamedButtons(icons)
        #expect(icons.contains { $0.name == "No colour" })
        #expect(icons.contains { $0.role == NSAccessibility.Role.textField.rawValue && $0.name == "Find an icon" })
    }

    /// The reader page in a real web view: the controls the page adds after
    /// rendering (fold chevrons, copy buttons, find bar) have names, a task
    /// in progress is a mixed box, a callout is a note.
    @Test func theReaderPageNamesItsControls() async throws {
        try "# Page\n\n## Part\n\nText.\n\n```swift\nlet a = 1\n```\n\n- [/] Half done\n\n> [!tip] Mind\n> Body\n".write(to: root.appending(path: "Page.md"), atomically: true, encoding: .utf8)
        store.openSynchronously(root)
        var web: WKWebView?
        let reader = ReaderView(request: ReaderRequest(path: "Page.md"), store: store, onOpen: { _, _, _ in }, onTag: { _ in }, onView: { web = $0 })
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: reader.environment(store))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        var found: String?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            guard let web else { continue }
            let script = """
                (() => { const q = (s, a) => document.querySelector(s)?.getAttribute(a) ?? "";
                  if (!document.querySelector('.code-copy')) return null;
                  window.daftar.findCommand('open');
                  return [q('.fold-toggle', 'aria-label'), q('.fold-toggle', 'aria-expanded'), q('.code-copy', 'aria-label'),
                    String(document.querySelector('input.task-list-item-checkbox')?.indeterminate), q('input.task-list-item-checkbox', 'aria-label'),
                    q('.callout', 'role'), q('#progress', 'role'), q('.find-close', 'aria-label'), q('.find-bar input', 'aria-label')].join('|'); })()
                """
            if let result = try? await web.evaluateJavaScript(script) as? String { found = result; break }
        }
        #expect(found == "Fold “Page”|true|Copy code|true|Half done, in progress|note|progressbar|Close find|Find in note")
    }
}
