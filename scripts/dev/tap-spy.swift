import CoreGraphics
import Foundation

// Listen-only session tap: prints key events with keycode/flags/userData for N seconds, to see what actually reaches taps.
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
    callback: { _, type, event, _ in
        print("type=\(type.rawValue) key=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=0x\(String(event.flags.rawValue, radix: 16)) userData=\(event.getIntegerValueField(.eventSourceUserData)) src=\(event.getIntegerValueField(.eventSourceStateID))")
        fflush(stdout)
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { print("tap create failed (permission?)"); exit(1) }
let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRunInMode(.defaultMode, seconds, false)
