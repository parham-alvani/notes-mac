import AppKit
import SwiftTerm
import SwiftUI

/// One shell for one window, started in the vault's folder the first time
/// the pane opens. It lives in the window's model, so hiding the pane does
/// not end the shell.
@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    private(set) var view: LocalProcessTerminalView?
    private(set) var title = "Terminal"
    private var dark: Bool?

    func view(in folder: URL?, dark: Bool) -> LocalProcessTerminalView {
        if let view {
            if self.dark != dark { paint(view, dark: dark) }
            return view
        }
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = Fonts.code(size: CGFloat(AppSettings.shared.terminalFontSize))
        view.processDelegate = self
        paint(view, dark: dark)
        start(view, in: folder)
        self.view = view
        return view
    }

    /// The person's own login shell, as Terminal.app starts it.
    private func start(_ view: LocalProcessTerminalView, in folder: URL?) {
        let configured = AppSettings.shared.shell
        let shell = configured.isEmpty ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : configured
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Daftar"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let name = "-" + (shell.split(separator: "/").last.map(String.init) ?? "zsh")
        view.startProcess(
            executable: shell, args: [], environment: environment.map { "\($0.key)=\($0.value)" },
            execName: name, currentDirectory: folder?.path ?? NSHomeDirectory())
    }

    /// naz on dark and Daylight on light, as everywhere else in the app.
    private func paint(_ view: LocalProcessTerminalView, dark: Bool) {
        self.dark = dark
        let palette: [UInt32] = dark
            ? [0x3A3A35, 0xFF5070, 0xA0FF40, 0xF0E890, 0x40D0FF, 0xF0A0F0, 0x80E5FF, 0xD0D0D0,
               0x707080, 0xFF7088, 0x20FFA0, 0xFFE040, 0x60D8FF, 0xFF69B4, 0xB8FFD0, 0xF5F5F0]
            : [0x2A2A28, 0xC01030, 0x5A7A00, 0x8A6A00, 0x0070A0, 0x8040A0, 0x00707A, 0x6A6A62,
               0x4A4A46, 0xC01030, 0x0A7A48, 0xA85200, 0x0070A0, 0xB02A70, 0x00707A, 0x2A2A28]
        view.installColors(palette.map { value in
            SwiftTerm.Color(
                red8: UInt16((value >> 16) & 0xFF), green8: UInt16((value >> 8) & 0xFF), blue8: UInt16(value & 0xFF))
        })
        view.nativeBackgroundColor = Self.color(dark ? 0x282826 : 0xEFEDE6)
        view.nativeForegroundColor = Self.color(dark ? 0xF5F5F0 : 0x2A2A28)
        view.caretColor = Self.color(dark ? 0xFFB040 : 0xA85200)
        view.selectedTextBackgroundColor = Self.color(dark ? 0x4A4A4A : 0xD8D5CC)
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    // The shell is gone: the next time the pane opens, a new one starts.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            view?.removeFromSuperview()
            view = nil
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct TerminalPane: NSViewRepresentable {
    var session: TerminalSession
    var folder: URL?
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        attach(to: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        attach(to: holder)
    }

    private func attach(to holder: NSView) {
        let view = session.view(in: folder, dark: scheme == .dark)
        guard view.superview !== holder else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            view.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
