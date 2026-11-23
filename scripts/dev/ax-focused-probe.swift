import AppKit
import ApplicationServices

// Usage: swift ax-focused-probe.swift [seconds]. Click into a field in another app; prints the focused element's role and attributes once a second.
func value(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
let seconds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 10 : 10
for _ in 0..<seconds {
    if let app = NSWorkspace.shared.frontmostApplication {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
    if let focused = value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
        let e = unsafeBitCast(focused, to: AXUIElement.self)
        var names: CFArray?
        AXUIElementCopyAttributeNames(e, &names)
        let list = (names as? [String]) ?? []
        print("role=\(value(e, kAXRoleAttribute) as? String ?? "?") subrole=\(value(e, kAXSubroleAttribute) as? String ?? "") roleDesc=\(value(e, kAXRoleDescriptionAttribute) as? String ?? "")")
        print("  editableAncestor=\(value(e, "AXEditableAncestor") != nil) highestEditable=\(value(e, "AXHighestEditableAncestor") != nil) AXEditable=\(String(describing: value(e, "AXEditable"))) selectedRange=\(list.contains(kAXSelectedTextRangeAttribute as String))")
    } else { print("no focused element") }
    sleep(1)
}
