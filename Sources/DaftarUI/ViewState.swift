import SwiftUI

/// SwiftUI's `State` property wrapper, by a name that is not also a macro.
///
/// From the macOS 27 SDK on, `@State` resolves to a macro whose plugin ships
/// only with Xcode, so with the command line tools alone it does not build.
/// A type alias can only name the type, and the type is the property wrapper
/// SwiftUI has always had, with the same storage and behaviour.
typealias ViewState<Value> = State<Value>
