import Foundation
import Testing
@testable import MacInterfaceController

struct WindowLayoutTests {
    private let visible = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
    private let current = CGRect(x: -1600, y: 150, width: 900, height: 600)

    @Test func halvesCoverVisibleAreaWithoutGaps() {
        let left = WindowLayoutGeometry.target(.windowLeft, current: current, visible: visible)
        let right = WindowLayoutGeometry.target(.windowRight, current: current, visible: visible)
        #expect(left.union(right) == visible)
        #expect(left.maxX == right.minX)
        #expect(left.height == 1055)
        #expect(WindowLayoutGeometry.target(.windowMaximize, current: current, visible: visible) == visible)
    }

    @Test func centeredHeightKeepsWidthAndEqualMargins() {
        let target = WindowLayoutGeometry.target(.windowCenterHeight, current: current, visible: visible)
        #expect(target.width == current.width)
        #expect(target.height == visible.height * 0.95)
        #expect(target.midX == visible.midX)
        #expect(target.midY == visible.midY)
        #expect(abs((target.minY - visible.minY) - (visible.maxY - target.maxY)) < 0.001)
    }

    @Test func centerPreservesSizeAndCustomHeightIsApplied() {
        let centered = WindowLayoutGeometry.target(.windowCenter, current: current, visible: visible)
        #expect(centered.size == current.size)
        #expect(centered.midX == visible.midX && centered.midY == visible.midY)
        let resized = WindowLayoutGeometry.target(.windowCenterHeight, current: current, visible: visible, heightPercent: 80)
        #expect(resized.height == 844)
    }

    @Test func screenCoordinatesHandleDisplaysAboveAndLeft() {
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        #expect(WindowLayoutGeometry.accessibilityFrame(above, primaryTop: 900) == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(WindowLayoutGeometry.accessibilityFrame(left, primaryTop: 900) == CGRect(x: -1920, y: -180, width: 1920, height: 1080))
    }

    @Test func screenChoiceUsesOverlapThenNearestForOffscreenWindows() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        #expect(WindowLayoutGeometry.screenIndex(for: CGRect(x: 900, y: 100, width: 400, height: 300), screens: screens) == 1)
        #expect(WindowLayoutGeometry.screenIndex(for: CGRect(x: -600, y: 0, width: 300, height: 300), screens: screens) == 0)
        #expect(WindowLayoutGeometry.screenIndex(for: current, screens: []) == nil)
    }

    @Test func restoreFitsMissingDisplayAndOversizedWindows() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let restored = WindowLayoutGeometry.fitted(CGRect(x: -1920, y: -900, width: 1920, height: 1080), in: screen)
        #expect(restored == screen)
        let normal = CGRect(x: 10, y: 50, width: 900, height: 600)
        #expect(WindowLayoutGeometry.fitted(normal, in: screen) == normal)
    }

    @Test func oversizedWidthAndInvalidRuntimePercentAreBounded() {
        let wide = CGRect(x: 0, y: 0, width: 3000, height: 900)
        let target = WindowLayoutGeometry.target(.windowCenterHeight, current: wide, visible: visible, heightPercent: .nan)
        #expect(target.width == visible.width)
        #expect(target.height == visible.height * 0.95)
        #expect(WindowLayoutGeometry.target(.windowCenterHeight, current: wide, visible: visible, heightPercent: 150).height == visible.height)
    }

    @Test func presetsPreserveEditsAndAvoidActiveCollisions() {
        let existing = [ShortcutRule(isEnabled: false, key: .l, modifiers: [.shift], action: .windowLeft),
                        ShortcutRule(key: .right, modifiers: [.control, .option], action: .finder)]
        let result = WindowLayoutPresets.addingMissing(to: existing)
        #expect(Array(result.prefix(2)) == existing)
        #expect(result.filter { $0.action == .windowLeft }.count == 1)
        #expect(result.first { $0.action == .windowRight }?.isEnabled == false)
        #expect(result.first { $0.action == .windowMaximize }?.isEnabled == true)
        #expect(WindowLayoutPresets.addingMissing(to: result) == result)
    }

    @Test func legacyShortcutsDecodeAndNewActionsRoundTrip() throws {
        let legacy = #"{"id":"F2B9B541-172D-4B05-96DD-6F75E0BCC683","isEnabled":true,"key":"space","modifiers":["shift"],"action":"toggleInputSource"}"#
        #expect(try JSONDecoder().decode(ShortcutRule.self, from: Data(legacy.utf8)).windowHeightPercent == nil)
        var rules = WindowLayoutPresets.rules
        rules[rules.count - 1].windowHeightPercent = 88
        let profile = PortableProfile(name: "창 배치", shortcuts: rules,
                                      corners: CornerPosition.allCases.map { HotCornerRule(position: $0, isEnabled: false, dwellSeconds: 0.35, action: .finder) },
                                      swapCommandControl: false, windowsFinderMode: false, windowSwitcherEnabled: false)
        #expect(try PortableProfile.decode(profile.encoded()) == profile)
        var invalid = profile
        invalid.shortcuts[0].windowHeightPercent = 101
        #expect(throws: (any Error).self) { try invalid.validated() }
    }
}
