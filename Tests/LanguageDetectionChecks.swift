import Foundation

@main
struct LanguageDetectionChecks {
    static func testSkipsUnavailableBestGuess() {
        expectEqual(availableDetectedLanguage(
            hypotheses: ["ca": 0.6, "en": 0.3, "de": 0.1],
            installedLanguages: ["en-US", "de-DE"], fallbackLanguage: "de-DE"
        ), "en")
    }

    static func testKeepsAvailableBestGuess() {
        expectEqual(availableDetectedLanguage(
            hypotheses: ["ca": 0.6, "en": 0.4],
            installedLanguages: ["ca-ES", "en-US"], fallbackLanguage: "en-US"
        ), "ca")
    }

    static func testUsesSiriFallbackOnlyAfterCandidates() {
        expectEqual(availableDetectedLanguage(
            hypotheses: ["ca": 1], installedLanguages: ["ko-KR"],
            fallbackLanguage: "ko-KR"
        ), "ko-KR")
    }

    static func testMissingFallbackKeepsUsefulErrorLanguage() {
        expectEqual(availableDetectedLanguage(
            hypotheses: ["ca": 1], installedLanguages: [], fallbackLanguage: "en-US"
        ), "ca")
    }

    static func testUndeterminedInputCanInheritPreviousSentence() {
        expectNil(availableDetectedLanguage(
            hypotheses: ["und": 1, "en": 0], installedLanguages: ["en-US"],
            fallbackLanguage: "en-US"
        ))
    }

    static func testPreservesChineseScriptForContextRouting() {
        expectEqual(availableDetectedLanguage(
            hypotheses: ["zh-Hant": 0.9, "en": 0.1],
            installedLanguages: ["zh-HK", "en-US"], fallbackLanguage: "en-US"
        ), "zh-Hant")
    }

    static func testHiWithEnglishInstalled() {
        expectEqual(detectAvailableLanguage(
            "Hi", installedLanguages: ["en-US"], fallbackLanguage: nil,
            debugEnabled: false
        ), "en")
    }

    static func expectEqual(_ actual: String?, _ expected: String, file: StaticString = #file, line: UInt = #line) {
        precondition(actual == expected, "Expected \(expected), got \(actual ?? "nil")", file: file, line: line)
    }

    static func expectNil(_ actual: String?, file: StaticString = #file, line: UInt = #line) {
        precondition(actual == nil, "Expected nil, got \(actual!)", file: file, line: line)
    }

    static func main() {
        testSkipsUnavailableBestGuess()
        testKeepsAvailableBestGuess()
        testUsesSiriFallbackOnlyAfterCandidates()
        testMissingFallbackKeepsUsefulErrorLanguage()
        testUndeterminedInputCanInheritPreviousSentence()
        testPreservesChineseScriptForContextRouting()
        testHiWithEnglishInstalled()
        print("Language detection checks passed (7)")
    }
}
