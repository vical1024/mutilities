import Carbon
import CoreGraphics
import Foundation

// Posts a physical-looking Shift+Space (HID level, untagged) so the app's event tap sees it like real typing.
let source = CGEventSource(stateID: .hidSystemState)
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(20_000)
}
post(CGKeyCode(kVK_Shift), down: true, flags: .maskShift)
post(CGKeyCode(kVK_Space), down: true, flags: .maskShift)
post(CGKeyCode(kVK_Space), down: false, flags: .maskShift)
post(CGKeyCode(kVK_Shift), down: false, flags: [])
