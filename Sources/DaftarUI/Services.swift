import AppKit
import DaftarCore

/// "Send to Daftar" from other apps: the Services menu's "Add to Daftar
/// Scratchpad" and "New Daftar Task" (`NSServices` in `Support/Info.plist`).
/// They work with no Daftar window open, and when the service started the
/// app: the store belongs to the app, and is waited for while it loads.
/// The spec is `send-to-daftar.md` in notes-linux's `docs/specs`.
@MainActor
final class DaftarServices: NSObject {
    static let shared = DaftarServices()

    /// The app's store, as quick capture has it; a test gives its own.
    var store: () -> VaultStore? = { QuickCaptureController.shared.store }
    /// Opens a `daftar://` address in this app, as a click on a link would.
    var deliver: (URL) -> Void = { DaftarServices.openInThisApp($0) }

    /// Starts answering the Services menu.
    func start() {
        NSApp.servicesProvider = self
        // The menu learns the services from the Info.plist; this asks it to look again.
        NSUpdateDynamicServices()
    }

    // MARK: The services, as AppKit calls them

    /// "Add to Daftar Scratchpad": the selection, or the link, at the end of
    /// today's section of the scratchpad.
    @objc func addToScratchpad(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let (text, url) = Self.read(pasteboard)
        guard let line = SendToDaftar.scratchpadLine(text: text, url: url) else {
            error.pointee = "There is no text to add." as NSString
            return
        }
        Task { await add(line) }
    }

    /// "New Daftar Task": the New Task form, filled with the selection.
    @objc func newTask(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let (text, url) = Self.read(pasteboard)
        guard let task = SendToDaftar.taskText(text: text, url: url), let address = SendToDaftar.newTaskURL(text: task) else {
            error.pointee = "There is no text for a task." as NSString
            return
        }
        Task {
            _ = await loadedStore()
            NSApp?.activate()
            deliver(address)
        }
    }

    // MARK: The work

    /// Adds [line]; a failure opens quick capture with it, so nothing sent is lost.
    @discardableResult
    func add(_ line: String) async -> String? {
        do {
            guard let store = await loadedStore() else { throw CaptureFailure.noVault }
            return try await store.addToScratchpad(line)
        } catch {
            let model = QuickCaptureController.shared.model
            QuickCaptureController.shared.show()
            model.draft = line
            model.error = "Not added to the scratchpad: " + ((error as? VaultMoves.Failure)?.description ?? error.localizedDescription)
            return nil
        }
    }

    /// The store once it has a vault and is not loading, waited for up to a
    /// minute: a service may be what started the app.
    func loadedStore(waiting limit: Duration = .seconds(60)) async -> VaultStore? {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if let store = store(), store.root != nil, !store.loading { return store }
            if let store = store(), store.root == nil, store.settings.vaultPath == nil { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The text and the link on [pasteboard]: a browser's selected link has both.
    static func read(_ pasteboard: NSPasteboard) -> (text: String?, url: String?) {
        let text = pasteboard.string(forType: .string)
        let url = pasteboard.string(forType: .URL)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { !$0.isFileURL })?.absoluteString
        return (text, url)
    }

    /// Hands [url] to this app's own handler of `daftar://`, which makes a
    /// window when none is open. Sent to this process, not to whichever
    /// app the system gives `daftar:` to, so a second copy never gets it.
    static func openInThisApp(_ url: URL) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        do {
            try event.sendEvent(options: [.noReply], timeout: TimeInterval(kAEDefaultTimeout))
        } catch {
            NSWorkspace.shared.open(url)
        }
    }
}

extension VaultStore {
    /// Adds [line] to the scratchpad (`scratchpad.note`), made when it is
    /// not there, at the end of [day]'s `## YYYY-MM-DD` section, made at the
    /// note's end by the day's first line. The editors save first and the
    /// file is read again, as quick capture does. Its vault path.
    @discardableResult
    func addToScratchpad(_ line: String, on day: Day = .today()) async throws -> String {
        guard root != nil else { throw CaptureFailure.noVault }
        guard !loading else { throw CaptureFailure.loading }
        await flushEditors()
        let path = try scratchpad()
        guard let text = text(of: path) else { throw CaptureFailure.unreadable(path) }
        try write(QuickCapture.append(line, to: text, heading: SendToDaftar.heading(on: day)), to: path)
        return path
    }
}
