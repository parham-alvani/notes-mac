import AppKit
import Carbon.HIToolbox
import DaftarCore
import Observation
import SwiftUI

/// Quick capture: a global shortcut, the menu bar or the command palette
/// opens a small floating panel with one line; Return adds it to the
/// capture note and closes the panel. It works with no window open and with
/// another app in front: the store belongs to the app, not to a window, and
/// the panel does not bring Daftar forward.
@MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()

    /// The app's store, given by the app's scenes when they appear.
    weak var store: VaultStore?
    let model = CaptureModel()
    private var panel: CapturePanel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: String?

    /// Follows `capture.hotkey` in the settings file from now on.
    func start(settings: AppSettings = .shared) {
        installHandler()
        follow(settings)
    }

    private func follow(_ settings: AppSettings) {
        let spec = withObservationTracking {
            settings.captureHotkey
        } onChange: {
            Task { @MainActor in self.follow(settings) }
        }
        register(spec)
    }

    /// Registers [spec] in place of the shortcut before. Carbon's hot keys
    /// need no Accessibility permission; another app may hold the same keys.
    private func register(_ spec: String) {
        guard spec != registered else { return }
        registered = spec
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        model.hotKeyProblem = nil
        guard !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let key = HotKeySpec.parse(spec) else {
            model.hotKeyProblem = "“\(spec)” is not a shortcut Daftar can read, so it is off."
            return
        }
        var modifiers: UInt32 = 0
        if key.command { modifiers |= UInt32(cmdKey) }
        if key.control { modifiers |= UInt32(controlKey) }
        if key.option { modifiers |= UInt32(optionKey) }
        if key.shift { modifiers |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4466_7472), id: 1)  // 'Dftr'
        let status = RegisterEventHotKey(key.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKey = ref
        } else {
            model.hotKeyProblem = status == eventHotKeyExistsErr
                ? "\(key.symbols) is taken by another app. Choose other keys."
                : "\(key.symbols) could not be registered (error \(status))."
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon calls on the main thread.
            MainActor.assumeIsolated { QuickCaptureController.shared.toggle() }
            return noErr
        }, 1, &pressed, nil, &handler)
    }

    /// The shortcut as a menu shows it, or empty when there is none.
    var shortcut: String {
        guard hotKey != nil, let registered else { return "" }
        return HotKeySpec.parse(registered)?.symbols ?? ""
    }

    func toggle() {
        if panel?.isKeyWindow == true { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? CapturePanel()
        if self.panel == nil {
            let view = CaptureView(model: model, add: { [weak self] task in self?.add(task: task) }, close: { [weak self] in self?.hide() })
            panel.contentView = CaptureView.hosting(view)
            self.panel = panel
        }
        model.error = nil
        model.target = store.map(Self.describeTarget) ?? "No vault is open."
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 560, height: 110))
        // On the screen with the pointer, a third of the way down.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.maxY - area.height / 3 - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        model.shown += 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Adds the typed line; the panel closes when it is written and shows
    /// what went wrong when it is not.
    func add(task: Bool) {
        guard let line = QuickCapture.line(model.draft, task: task) else { return }
        guard let store else {
            model.error = "No vault is open."
            return
        }
        // Cleared at once, so a second Return adds nothing twice.
        let draft = model.draft
        model.draft = ""
        Task {
            do {
                try await store.capture(line)
                model.asTask = false
                hide()
            } catch {
                model.draft = draft
                model.error = (error as? VaultMoves.Failure)?.description ?? error.localizedDescription
            }
        }
    }

    /// "Journal/2026-10-26.md › Inbox": where a capture goes.
    static func describeTarget(_ store: VaultStore) -> String {
        let target = store.captureTargetPath
        let heading = store.settings.captureHeading.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? target : target + " › " + heading
    }
}

/// What the panel shows, kept while it is closed: a draft closed with a
/// click elsewhere is there when it opens again.
@MainActor @Observable
final class CaptureModel {
    var draft = ""
    var asTask = false
    var target = ""
    var error: String?
    /// Counts the times the panel opened, so the field takes the keys each time.
    var shown = 0
    /// Why the global shortcut is off, for the Settings window.
    var hotKeyProblem: String?
}

/// A floating panel that takes the keys without bringing Daftar forward,
/// on every Space and over full-screen apps.
final class CapturePanel: NSPanel, NSWindowDelegate {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 110),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    /// Escape closes it.
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// A click in another window closes it; the draft stays.
    func windowDidResignKey(_ notification: Notification) { orderOut(nil) }
}

/// The panel's one line, with the note it goes to.
struct CaptureView: View {
    @Bindable var model: CaptureModel
    var add: (_ task: Bool) -> Void
    var close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.asTask ? "checkmark.square" : "square.and.pencil")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26)
                TextField(model.asTask ? "Add a task" : "Capture a thought", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { add(model.asTask) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        add(true)
                        return .handled
                    }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            HStack(spacing: 8) {
                Toggle("Task", isOn: $model.asTask).toggleStyle(.checkbox)
                Text("→ \(model.target)").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                // ⌘↩ in the field adds a task whatever the box says.
                Button("Add as Task ⌘↩") { add(true) }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(Palette.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 560)
        .tint(Palette.accent)
        .onAppear { focused = true }
        .onChange(of: model.shown) { focused = true }
    }

    /// The view in the panel, which has no title bar to leave room for.
    static func hosting(_ view: CaptureView) -> NSHostingView<CaptureView> {
        let hosting = NSHostingView(rootView: view)
        hosting.safeAreaRegions = []
        return hosting
    }
}

/// Settings › Capture: the shortcut, the note and the heading.
struct CaptureSettings: View {
    @Environment(VaultStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        let spec = HotKeySpec.parse(settings.captureHotkey)
        let problem = QuickCaptureController.shared.model.hotKeyProblem
        Form {
            Section {
                TextField("Shortcut", text: $settings.captureHotkey, prompt: Text("Off"))
                LabeledContent("Keys") {
                    Text(spec?.symbols ?? "Off").foregroundStyle(problem == nil ? .secondary : Palette.red)
                }
                TextField("Note", text: $settings.captureTarget, prompt: Text("daily"))
                TextField("Under the heading", text: $settings.captureHeading, prompt: Text("The end of the note"))
            } footer: {
                Text(problem ?? "The shortcut opens the capture panel from any app; it is written as ctrl+opt+n, cmd+shift+space or f13, and empty turns it off. “daily” is today's note, as ⌘3 opens it; a path such as Inbox.md names one note. Return adds the line, ⌘↩ adds it as a task.")
            }
        }
        .formStyle(.grouped)
    }
}

extension VaultStore {
    /// The note a capture goes to now, before it is made.
    var captureTargetPath: String {
        let target = settings.captureTarget.trimmingCharacters(in: .whitespaces)
        if target.isEmpty || target.lowercased() == "daily" { return periodic.path(for: .today()) }
        let path = Vault.isNote(target) ? target : target + ".md"
        return index.files.first { Slugs.fold($0) == Slugs.fold(path) } ?? path
    }

    /// Adds [line] to the capture note, made first when it is not there: the
    /// periodic note from its template, a named note empty. The editors save
    /// first and the file is read again, so the line goes into the note as
    /// it is on disk; the write is an ordinary one, so the index, the sync
    /// and the reading marks follow as they do for any edit. Its vault path.
    @discardableResult
    func capture(_ line: String) async throws -> String {
        guard root != nil else { throw CaptureFailure.noVault }
        guard !loading else { throw CaptureFailure.loading }
        await flushEditors()
        let target = settings.captureTarget.trimmingCharacters(in: .whitespaces)
        let path: String
        if target.isEmpty || target.lowercased() == "daily" {
            path = try periodicNote()
        } else if index.files.contains(captureTargetPath) {
            path = captureTargetPath
        } else {
            let made = captureTargetPath
            path = try createNote(named: String(made.split(separator: "/").last!.dropLast(3)), in: QuickSwitcher.folder(of: made))
        }
        guard let text = text(of: path) else { throw CaptureFailure.unreadable(path) }
        let heading = settings.captureHeading.trimmingCharacters(in: .whitespaces)
        try write(QuickCapture.append(line, to: text, heading: heading.isEmpty ? nil : heading), to: path)
        return path
    }
}

enum CaptureFailure: LocalizedError {
    case noVault
    case loading
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noVault: "No vault is open."
        case .loading: "The vault is still loading. Try again in a moment."
        case .unreadable(let path): "\(path) could not be read. Nothing was written."
        }
    }
}
