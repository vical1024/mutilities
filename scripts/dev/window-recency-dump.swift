import AppKit
import ApplicationServices

// Lists every regular app's AX windows with their CGWindowID and position in the on-screen front-to-back order.
@_silgen_name("_AXUIElementGetWindow")
func axGetWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var order: [CGWindowID: Int] = [:]
for item in all {
    guard (item[kCGWindowLayer as String] as? Int) == 0, let n = item[kCGWindowNumber as String] as? NSNumber else { continue }
    order[CGWindowID(n.uint32Value)] = order.count
    print("CG #\(order.count - 1) id=\(n) pid=\(item[kCGWindowOwnerPID as String] ?? "?") owner=\(item[kCGWindowOwnerName as String] ?? "?")")
}
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &v) == .success, let ws = v as? [AXUIElement] else { continue }
    for w in ws {
        var id: CGWindowID = 0
        let err = axGetWindowID(w, &id)
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
        var m: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
        print("AX \(app.localizedName ?? "?") pid=\(app.processIdentifier) id=\(id) err=\(err.rawValue) recency=\(order[id].map(String.init) ?? "none") min=\(String(describing: m)) title=\((t as? String ?? "").prefix(50))")
    }
}
