import Foundation

@main
struct SystemSettingsInspect {
    static func main() throws {
        let snapshot = try LocalSystemSettingsBackend().capture()
        try snapshot.validate()
        print("Read-only inspection: \(snapshot.preferences.count) managed preference entries, \(snapshot.hidMappings.count) HID mappings")
        for item in snapshot.preferences {
            print("\(item.address.currentHost ? "current host" : "any host"): \(item.address.domain) / \(item.address.key)")
        }
    }
}
