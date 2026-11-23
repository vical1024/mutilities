import AppKit
import ApplicationServices

// Prints what Chrome reports as its focused element (works while another app is frontmost), plus its ancestors.
func value(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { print("Chrome not running"); exit(1) }
let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
guard let focused = value(appElement, kAXFocusedUIElementAttribute) else { print("no focused element"); exit(0) }
var element: AXUIElement? = unsafeBitCast(focused, to: AXUIElement.self)
var depth = 0
while let e = element, depth < 8 {
    var names: CFArray?
    AXUIElementCopyAttributeNames(e, &names)
    let list = (names as? [String]) ?? []
    print("[\(depth)] role=\(value(e, kAXRoleAttribute) as? String ?? "?") subrole=\(value(e, kAXSubroleAttribute) as? String ?? "") desc=\(value(e, kAXRoleDescriptionAttribute) as? String ?? "") title=\((value(e, kAXTitleAttribute) as? String ?? "").prefix(40))")
    print("     editableAncestor=\(value(e, "AXEditableAncestor") != nil) highest=\(value(e, "AXHighestEditableAncestor") != nil) AXEditable=\(String(describing: value(e, "AXEditable"))) selRange=\(list.contains(kAXSelectedTextRangeAttribute as String))")
    if depth == 0 { print("     attrs: \(list.joined(separator: ", "))") }
    element = value(e, kAXParentAttribute).map { unsafeBitCast($0, to: AXUIElement.self) }
    depth += 1
}
