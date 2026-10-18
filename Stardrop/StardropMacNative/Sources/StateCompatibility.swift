import SwiftUI

// Explicitly select SwiftUI's property wrapper. New SDKs also expose a State
// macro whose plug-in is unavailable in the standalone Command Line Tools.
// The alias keeps the existing macOS 13-compatible state implementation.
typealias NativeState<Value> = SwiftUI.State<Value>
