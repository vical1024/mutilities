import CoreGraphics
import Foundation
import Darwin

public final class LiveDisplayHardware: DisplayHardware {
    private typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
    private let library: UnsafeMutableRawPointer
    private let configure: Configure
    public let builtInID: CGDirectDisplayID

    public static func activeDisplays() throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success,
              count < ids.count else { throw DisplayFailure("활성 화면 목록을 확인하지 못했습니다.") }
        return Array(ids.prefix(Int(count)))
    }

    public static func activeBuiltInID() throws -> CGDirectDisplayID {
        guard let id = try activeDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw DisplayFailure("켜진 내장 화면을 찾지 못했습니다. MacBook을 열고 다시 시도해 주세요.")
        }
        return id
    }

    public init(builtInID: CGDirectDisplayID) throws {
        guard CGDisplayIsBuiltin(builtInID) != 0 else { throw DisplayFailure("내장 화면 식별자가 유효하지 않습니다.") }
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
            throw DisplayFailure("이 macOS에서는 내장 화면 제어를 사용할 수 없습니다.")
        }
        guard let symbol = dlsym(library, "SLSConfigureDisplayEnabled") else {
            dlclose(library)
            throw DisplayFailure("이 macOS에서는 내장 화면 끄기를 지원하지 않습니다.")
        }
        self.library = library
        configure = unsafeBitCast(symbol, to: Configure.self)
        self.builtInID = builtInID
    }

    deinit { dlclose(library) }

    public func snapshot() throws -> DisplaySnapshot {
        let ids = try Self.activeDisplays()
        return DisplaySnapshot(builtInActive: ids.contains(builtInID), externalIDs: Set(ids.filter {
            $0 != builtInID && CGDisplayIsBuiltin($0) == 0 && CGDisplayIsOnline($0) != 0
                && CGDisplayPixelsWide($0) > 0 && CGDisplayPixelsHigh($0) > 0
        }))
    }

    public func setBuiltInEnabled(_ enabled: Bool) throws {
        let before = try snapshot()
        if enabled && before.builtInActive { return }
        if !enabled && before.externalIDs.isEmpty { throw DisplayFailure("사용할 수 있는 외장 화면이 없어 내장 화면을 끄지 않았습니다.") }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else { throw DisplayFailure("화면 변경을 시작하지 못했습니다 (\(begin.rawValue)).") }
        let result = configure(configuration, builtInID, enabled)
        guard result == CGError.success.rawValue else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayFailure("내장 화면을 \(enabled ? "켜지" : "끄지") 못했습니다 (\(result)).")
        }
        // Never persist a disabled panel into the login session or system preferences.
        // WindowServer reverts this scope when the owning helper exits, even on SIGKILL.
        let commit = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
        guard commit == .success else { throw DisplayFailure("화면 변경을 적용하지 못했습니다 (\(commit.rawValue)).") }
        for _ in 0..<20 {
            if try snapshot().builtInActive == enabled { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DisplayFailure("내장 화면 \(enabled ? "켜짐" : "꺼짐")을 확인하지 못했습니다.")
    }
}
