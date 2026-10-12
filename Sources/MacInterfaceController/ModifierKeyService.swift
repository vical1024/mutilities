import Foundation

// Read-only detection; runtime mappings are owned by the event tap.
enum ModifierKeyService {
    static func hasPersistentCommandControlSwap(in defaults: [String: Any]) -> Bool {
        struct Mapping: Hashable {
            let source: UInt64
            let destination: UInt64
        }

        let leftControl: UInt64 = 30_064_771_296
        let leftCommand: UInt64 = 30_064_771_299
        let rightControl: UInt64 = 30_064_771_300
        let rightCommand: UInt64 = 30_064_771_303
        let required: Set<Mapping> = [
            Mapping(source: leftControl, destination: leftCommand),
            Mapping(source: leftCommand, destination: leftControl),
            Mapping(source: rightControl, destination: rightCommand),
            Mapping(source: rightCommand, destination: rightControl)
        ]

        for (key, value) in defaults where key.hasPrefix("com.apple.keyboard.modifiermapping.") {
            guard let rawMappings = value as? [[String: Any]] else { continue }
            let mappings = Set(rawMappings.compactMap { item -> Mapping? in
                guard let source = (item["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value,
                      let destination = (item["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value
                else { return nil }
                return Mapping(source: source, destination: destination)
            })
            if required.isSubset(of: mappings) { return true }
        }
        return false
    }
}
