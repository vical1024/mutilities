import CoreGraphics
import Foundation

// Usage: swift post-key.swift <keycode>. Posts a plain key press at the HID level.
let key = CGKeyCode(CommandLine.arguments.dropFirst().first.flatMap { UInt16($0) } ?? 53)
let source = CGEventSource(stateID: .hidSystemState)
for down in [true, false] {
    CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
    usleep(20_000)
}
