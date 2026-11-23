import CoreGraphics
import Foundation

// Lists active event taps: owner pid, enabled flag, tap point and event mask.
var count: UInt32 = 0
CGGetEventTapList(0, nil, &count)
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
CGGetEventTapList(count, &taps, &count)
for t in taps.prefix(Int(count)) {
    let name = (try? String(contentsOfFile: "/proc/\(t.tappingProcess)/comm")) ?? ""
    print("tapper pid=\(t.tappingProcess) target=\(t.processBeingTapped) enabled=\(t.enabled) place=\(t.tapPoint.rawValue) options=\(t.options.rawValue) mask=\(String(t.eventsOfInterest, radix: 16)) \(name)")
}
