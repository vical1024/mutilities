import CoreGraphics
import Foundation

// Read-only: shows which displays are active/online/asleep and which one is built-in.
var n: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &n)
var online = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetOnlineDisplayList(n, &online, &n)
var m: UInt32 = 0
CGGetActiveDisplayList(0, nil, &m)
var active = [CGDirectDisplayID](repeating: 0, count: Int(m))
CGGetActiveDisplayList(m, &active, &m)
print("online=\(online.prefix(Int(n))) active=\(active.prefix(Int(m)))")
for id in online.prefix(Int(n)) {
    print("id=\(id) builtin=\(CGDisplayIsBuiltin(id) != 0) active=\(CGDisplayIsActive(id) != 0) asleep=\(CGDisplayIsAsleep(id) != 0) main=\(CGDisplayIsMain(id) != 0) mirror=\(CGDisplayIsInMirrorSet(id) != 0) size=\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))")
}
