import Foundation
import Testing
@testable import MacInterfaceController

struct HIDMappingParserTests {
    private let mapping = HIDMapping(source: 30064771296, destination: 30064771299)
    private let value = "({HIDKeyboardModifierMappingSrc = 30064771296; HIDKeyboardModifierMappingDst = 30064771299;})"

    @Test func currentMacTableWith132NullRows() throws {
        let text = "RegistryID  Key  Value\n" + (1...132).map { "\(String($0, radix: 16)) UserKeyMapping (null)" }.joined(separator: "\n")
        let snapshot = try HIDMappingParser.parse(Data(text.utf8))
        #expect(snapshot.values.count == 132)
        #expect(!snapshot.hasMappings)
        #expect(try snapshot.commonMappings().isEmpty)
    }

    @Test func legacyNullAndEmptyFormats() throws {
        for text in ["(null)\n", "null", "()", "[]"] {
            #expect(try HIDMappingParser.parse(Data(text.utf8)).commonMappings().isEmpty)
        }
    }

    @Test func legacyMappingAndJSON() throws {
        #expect(try HIDMappingParser.parse(Data(value.utf8)).commonMappings() == [mapping])
        let json = #"[{"HIDKeyboardModifierMappingSrc":30064771296,"HIDKeyboardModifierMappingDst":30064771299}]"#
        #expect(try HIDMappingParser.parse(Data(json.utf8)).commonMappings() == [mapping])
    }

    @Test func tableSupportsMultilineMappingsAndIdenticalDevices() throws {
        let text = "RegistryID Key Value\n1000 UserKeyMapping (\n{\nHIDKeyboardModifierMappingSrc = 30064771296;\nHIDKeyboardModifierMappingDst = 30064771299;\n}\n)\n1001 UserKeyMapping \(value)"
        let snapshot = try HIDMappingParser.parse(Data(text.utf8))
        #expect(snapshot.hasMappings)
        #expect(try snapshot.commonMappings() == [mapping])
    }

    @Test func differentDevicesAreDetectedButNeverFlattenedForBackup() throws {
        let text = "RegistryID Key Value\n1000 UserKeyMapping (null)\n1001 UserKeyMapping \(value)"
        let snapshot = try HIDMappingParser.parse(Data(text.utf8))
        #expect(snapshot.hasMappings)
        #expect(throws: (any Error).self) { try snapshot.commonMappings() }
    }

    @Test func malformedOrTruncatedTableFailsClosed() {
        for text in ["", "RegistryID Key Value", "RegistryID Key Value\n1000 WrongKey (null)", "RegistryID Key Value\n1000 UserKeyMapping (", "RegistryID Key Value\n1000 UserKeyMapping (null)\ntrailing garbage", "RegistryID Key Value\n1000 UserKeyMapping (null)\n1000 UserKeyMapping (null)"] {
            #expect(throws: (any Error).self) { try HIDMappingParser.parse(Data(text.utf8)) }
        }
    }

    @Test func invalidNumbersAndDuplicateSourcesAreRejected() {
        for text in [
            #"[{"HIDKeyboardModifierMappingSrc":true,"HIDKeyboardModifierMappingDst":1}]"#,
            #"[{"HIDKeyboardModifierMappingSrc":-1,"HIDKeyboardModifierMappingDst":1}]"#,
            #"[{"HIDKeyboardModifierMappingSrc":1.5,"HIDKeyboardModifierMappingDst":1}]"#,
            #"[{"HIDKeyboardModifierMappingSrc":1}]"#,
            "(\(value.dropFirst().dropLast()),\(value.dropFirst().dropLast()))"
        ] { #expect(throws: (any Error).self) { try HIDMappingParser.parse(Data(text.utf8)) } }
    }
}
