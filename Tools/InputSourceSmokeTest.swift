import Carbon
import Darwin
import Foundation

@main
struct InputSourceSmokeTest {
    @MainActor
    static func main() {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let before = sourceID(original)
        var failure: String?
        var switched = ""

        do {
            try InputSourceManager.shared.toggleKoreanEnglish()
            switched = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
            if switched == before {
                failure = "입력 소스가 변경되지 않았습니다."
            }
        } catch {
            failure = error.localizedDescription
        }

        let restoreStatus = TISSelectInputSource(original)
        let restored = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        if restoreStatus != noErr || restored != before {
            failure = "원래 입력 소스 복원에 실패했습니다. 상태: \(restoreStatus)"
        }

        print("before=\(before)")
        print("switched=\(switched)")
        print("restored=\(restored)")
        if let failure {
            fputs("error=\(failure)\n", stderr)
            exit(1)
        }
    }

    private static func sourceID(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String ?? ""
    }
}
