import Foundation
import Testing
@testable import MacInterfaceController

private final class MemoryFunctionKeys: FunctionKeyBackend {
    var current = false
    var original: Bool?
    var applied: Bool?
    var isGuarded = false
    var begins = 0
    var failStart = false
    func read() throws -> Bool { current }
    func begin(standard: Bool) throws {
        try end()
        if failStart { throw ProfileError.invalid("unavailable") }
        begins += 1
        original = current
        applied = standard
        current = standard
        isGuarded = true
    }
    func end() throws {
        if let original, current == applied { current = original }
        original = nil
        applied = nil
        isGuarded = false
    }
}

struct FunctionKeyTests {
    @Test func appliesBothModesAndRestoresOriginalOnDisable() {
        let backend = MemoryFunctionKeys()
        let controller = FunctionKeyController(backend: backend)
        controller.apply(true)
        #expect(backend.current)
        controller.apply(false)
        #expect(!backend.current)
        controller.apply(true)
        controller.apply(nil)
        #expect(!backend.current)
        #expect(!backend.isGuarded)
        #expect(controller.appliedStandard == nil)
    }
    @Test func preservesAnInitiallyStandardKeyboard() {
        let backend = MemoryFunctionKeys()
        backend.current = true
        let controller = FunctionKeyController(backend: backend)
        controller.apply(false)
        controller.apply(nil)
        #expect(backend.current)
    }
    @Test func unrelatedSettingsRefreshDoesNotReplaceSessionBaseline() {
        let backend = MemoryFunctionKeys()
        let controller = FunctionKeyController(backend: backend)
        controller.apply(true)
        controller.apply(true)
        #expect(backend.begins == 1)
        controller.apply(nil)
        #expect(!backend.current)
    }
    @Test func startupWithoutAConfiguredModeDoesNotChangeKeyboard() {
        let backend = MemoryFunctionKeys()
        backend.current = true
        let controller = FunctionKeyController(backend: backend)
        controller.apply(nil)
        #expect(backend.begins == 0)
        #expect(backend.current)
    }
    @Test func failureDoesNotClaimAppliedMode() {
        let backend = MemoryFunctionKeys()
        backend.failStart = true
        let controller = FunctionKeyController(backend: backend)
        controller.apply(true)
        #expect(controller.error != nil)
        #expect(controller.appliedStandard == nil)
        #expect(!backend.current)
    }
    @Test func laterExternalChangeIsPreservedOnRelease() {
        let backend = MemoryFunctionKeys()
        let controller = FunctionKeyController(backend: backend)
        controller.apply(true)
        backend.current = false
        controller.refresh()
        #expect(controller.error != nil)
        controller.apply(nil)
        #expect(!backend.current)
    }
    @Test func retryRepairsAnExternallyChangedMode() {
        let backend = MemoryFunctionKeys()
        let controller = FunctionKeyController(backend: backend)
        controller.apply(true)
        backend.current = false
        controller.refresh()
        #expect(controller.error != nil)
        controller.apply(true)
        #expect(backend.current)
        #expect(controller.error == nil)
        #expect(backend.begins == 2)
        controller.apply(nil)
        #expect(!backend.current)
    }
    @Test func optionalModeMigratesAndTravelsWithProfile() throws {
        var profile = PortableProfile(name: "Fn", shortcuts: [],
            corners: CornerPosition.allCases.map { HotCornerRule(position: $0, isEnabled: false, dwellSeconds: 0.35, action: .finder) },
            swapCommandControl: false, windowsFinderMode: false, windowSwitcherEnabled: false)
        profile.version = 2
        #expect(try PortableProfile.decode(profile.encoded()).standardFunctionKeys == nil)
        profile.version = 3
        profile.standardFunctionKeys = true
        #expect(try PortableProfile.decode(profile.encoded()).standardFunctionKeys == true)
        profile.standardFunctionKeys = false
        #expect(try PortableProfile.decode(profile.encoded()).standardFunctionKeys == false)
    }
}
