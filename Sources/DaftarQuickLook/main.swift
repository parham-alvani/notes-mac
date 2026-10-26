// An app extension starts in Foundation's `NSExtensionMain`, which runs the
// class that Info.plist's `NSExtensionPrincipalClass` names. Xcode links
// with `-e _NSExtensionMain`; SwiftPM builds a plain executable, so its
// `main` calls it.
import Foundation

typealias ExtensionMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSExtensionMain") else { fatalError("no NSExtensionMain") }
exit(unsafeBitCast(symbol, to: ExtensionMain.self)(CommandLine.argc, CommandLine.unsafeArgv))
