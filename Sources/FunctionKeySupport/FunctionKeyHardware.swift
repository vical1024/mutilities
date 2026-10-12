import Foundation
import IOKit
import IOKit.hidsystem

public enum FunctionKeyHardware {
    public static func read() throws -> Bool {
        try withConnection { connection in
            var value: Unmanaged<CFTypeRef>?
            guard IOHIDCopyCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, &value) == KERN_SUCCESS,
                  let number = value?.takeRetainedValue() as? NSNumber,
                  [0, 1].contains(number.intValue) else { throw Failure("기능 키 모드를 읽지 못했습니다. 이 키보드가 macOS 기능 키 전환을 지원하는지 확인해 주세요.") }
            return number.boolValue
        }
    }

    public static func write(_ standard: Bool) throws {
        try withConnection { connection in
            let result = IOHIDSetCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, NSNumber(value: standard ? 1 : 0))
            guard result == KERN_SUCCESS else { throw Failure("기능 키 모드를 적용하지 못했습니다 (\(result)).") }
        }
        guard try read() == standard else { throw Failure("기능 키 모드가 적용되지 않았습니다.") }
    }

    private static func withConnection<T>(_ action: (io_connect_t) throws -> T) throws -> T {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { throw Failure("키보드 설정 장치를 찾지 못했습니다.") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            throw Failure("키보드 기능 키 설정에 접근할 수 없습니다.")
        }
        defer { IOServiceClose(connection) }
        return try action(connection)
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
