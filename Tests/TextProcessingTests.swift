import XCTest
@testable import Relay

nonisolated final class ITNProcessorTests: XCTestCase {

    private func itn(_ s: String) -> String { ITNProcessor.process(s) }

    func testCardinalNumbers() {
        XCTAssertEqual(itn("I have five apples"), "I have 5 apples")
        XCTAssertEqual(itn("three hundred fifty"), "350")
        XCTAssertEqual(itn("two hundred and fifty"), "250")
        XCTAssertEqual(itn("two thousand twenty six"), "2026")
        XCTAssertEqual(itn("there were forty two of them"), "there were 42 of them")
    }

    func testYears() {
        XCTAssertEqual(itn("twenty twenty six"), "2026")
        XCTAssertEqual(itn("nineteen eighty four"), "1984")
    }

    func testCurrency() {
        XCTAssertEqual(itn("I have two hundred and fifty dollars"), "I have $250")
        XCTAssertEqual(itn("that is fifty cents"), "that is $0.50")
        XCTAssertEqual(itn("ten dollars and five cents"), "$10.05")
        XCTAssertEqual(itn("five dollars"), "$5")
    }

    func testPercent() {
        XCTAssertEqual(itn("fifty percent"), "50%")
        XCTAssertEqual(itn("one hundred percent sure"), "100% sure")
    }

    func testOrdinals() {
        XCTAssertEqual(itn("first"), "1st")
        XCTAssertEqual(itn("the third option"), "the 3rd option")
        XCTAssertEqual(itn("twenty first"), "21st")
        XCTAssertEqual(itn("the twenty third of may"), "the 23rd of may")
    }

    func testNoFalsePositives() {
        XCTAssertEqual(itn("I'll be there in a second"), "I'll be there in a second")
        XCTAssertEqual(itn("no one is here"), "no one is here")
        XCTAssertEqual(itn("hello world"), "hello world")
    }
}

nonisolated final class TranscriptPostProcessorTests: XCTestCase {

    private func apply(_ text: String, _ rules: [TextReplacementRule]) -> String {
        TranscriptPostProcessor.applyReplacements(text, rules: rules)
    }

    func testBasicReplacement() {
        let rule = TextReplacementRule(pattern: #"\bgpt\b"#, replacement: "GPT", caseInsensitive: true)
        XCTAssertEqual(apply("open gpt please", [rule]), "open GPT please")
    }

    func testCaptureGroupTemplate() {
        let rule = TextReplacementRule(pattern: "(foo)(bar)", replacement: "$2$1")
        XCTAssertEqual(apply("foobar", [rule]), "barfoo")
    }

    func testCaseInsensitiveFlag() {
        let sensitive = TextReplacementRule(pattern: "hello", replacement: "hi", caseInsensitive: false)
        XCTAssertEqual(apply("HELLO world", [sensitive]), "HELLO world")
        let insensitive = TextReplacementRule(pattern: "hello", replacement: "hi", caseInsensitive: true)
        XCTAssertEqual(apply("HELLO world", [insensitive]), "hi world")
    }

    func testInvalidPatternIsSkipped() {
        let invalid = TextReplacementRule(pattern: "(", replacement: "x")
        let valid = TextReplacementRule(pattern: "cat", replacement: "dog")
        XCTAssertEqual(apply("cat", [invalid, valid]), "dog")
    }

    func testDisabledRuleIsSkipped() {
        let rule = TextReplacementRule(pattern: "cat", replacement: "dog", enabled: false)
        XCTAssertEqual(apply("cat", [rule]), "cat")
    }

    func testEmptyPatternIsSkipped() {
        let rule = TextReplacementRule(pattern: "", replacement: "x")
        XCTAssertEqual(apply("anything", [rule]), "anything")
    }

    func testRulesApplyInOrder() {
        let first = TextReplacementRule(pattern: "a", replacement: "b")
        let second = TextReplacementRule(pattern: "b", replacement: "c")
        XCTAssertEqual(apply("a", [first, second]), "c")
    }
}
