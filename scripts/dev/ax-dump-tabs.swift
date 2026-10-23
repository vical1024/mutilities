import AppKit
import ApplicationServices

// Usage: swift ax-dump-tabs.swift <bundle id>. Prints the AX path to every AXTabGroup of each window.
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func dump(_ e: AXUIElement, indent: Int) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
    print(String(repeating: "  ", count: indent) + "\(role)/\(sub) value=\(String(describing: attr(e, kAXValueAttribute))) title=\(attr(e, kAXTitleAttribute) as? String ?? "") desc=\(attr(e, kAXDescriptionAttribute) as? String ?? "")")
    if indent < 8 { for k in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { dump(k, indent: indent + 1) } }
}
func walk(_ e: AXUIElement, depth: Int, path: String) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    if role == "AXTabGroup" {
        let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
        print("TABGROUP depth=\(depth) path=\(path) children=\(kids.count)")
        for k in kids.prefix(60) { dump(k, indent: 1) }
        return
    }
    guard depth < 9, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for k in kids { walk(k, depth: depth + 1, path: path + "/" + role) }
}
let bundle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.google.Chrome"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("not running"); exit(1) }
let el = AXUIElementCreateApplication(app.processIdentifier)
print("trusted:", AXIsProcessTrusted())
AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
for w in attr(el, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
    print("WINDOW", attr(w, kAXTitleAttribute) as? String ?? "")
    walk(w, depth: 0, path: "")
}
