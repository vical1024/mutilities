import Foundation
import Testing
@testable import MacInterfaceController

struct LocalizationTests {
    @Test func languageSwitchTranslatesExistingStatusWithoutChangingSource() {
        let status = "활성 외장 화면 2개"
        #expect(L10n.text(status, language: .english) == "2 active external displays")
        #expect(L10n.text(status, language: .korean) == status)
        #expect(L10n.text("앱 설정", language: .english) == "App Settings")
    }

    @Test func nestedErrorsAndMultipleLinesAreTranslatedAtDisplayTime() {
        let source = "시작 백업 실패: Dock 설정을 읽지 못했습니다."
        #expect(L10n.text(source, language: .english) == "Startup backup failed: Could not read Dock settings.")
        #expect(L10n.text("키보드\n설정 점검", language: .english) == "Keyboard\nSettings Check")
    }

    @Test func templateArgumentsKeepLiteralBracesAndPercentSigns() {
        let source = "저장한 {1} 100%.json · 단축키 3개 · Hot Corner 2개. 현재 설정은 자동 백업됩니다."
        #expect(L10n.text(source, language: .english) == "저장한 {1} 100%.json · 3 shortcuts · 2 hot corners. Your current settings will be backed up.")
        #expect(L10n.text("Custom name 100% {0}", language: .english) == "Custom name 100% {0}")
    }

    @Test func everyCatalogEntryPreservesItsArguments() throws {
        let regex = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func arguments(_ string: String) -> [String] {
            regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
                .compactMap { Range($0.range, in: string).map { String(string[$0]) } }.sorted()
        }
        for (key, translated) in L10n.english {
            #expect(!translated.isEmpty)
            #expect(arguments(key) == arguments(translated), "Mismatched arguments: \(key)")
            #expect(L10n.text(key, language: .english) == translated)
        }
    }
}
