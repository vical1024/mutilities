import Testing
@testable import MacInterfaceController

struct EnglishAssistTests {
    @Test func picksLastKoreanSentenceOfLastLine() {
        #expect(EnglishAssistController.lastSentence(in: "첫 줄입니다.\n오늘 회의가 길어졌어요") == "오늘 회의가 길어졌어요")
        #expect(EnglishAssistController.lastSentence(in: "안녕하세요. 내일 만날 수 있을까요?") == "내일 만날 수 있을까요")
    }

    @Test func ignoresNonKoreanOrTinyText() {
        #expect(EnglishAssistController.lastSentence(in: "Hello there, how are you") == nil)
        #expect(EnglishAssistController.lastSentence(in: "가") == nil)
        #expect(EnglishAssistController.lastSentence(in: "") == nil)
    }
}
