import XCTest
@testable import Aloud

final class DictionaryTests: XCTestCase {
    func testLocalAppLinkReadsOnlyItsLabel() {
        let raw = "119 项相关测试通过。[新版应用包](/Users/reader/.codex/worktrees/3144/aloud/build/念.app)已生成。"
        XCTAssertEqual(Dictionary_.apply(raw, prefs: Prefs(), rules: []), "119 项相关测试通过。新版应用包已生成。")
    }

    func testLinkDestinationsWithSpacesParenthesesAndTitlesAreNotSpoken() {
        for destination in [
            "</Users/reader/My Project/念.app>",
            "/Users/reader/build(backup)/念.app",
            "https://example.com/releases?q=latest#download",
            "https://example.com \"下载页面\"",
        ] {
            XCTAssertEqual(Dictionary_.apply("打开[新版应用包](\(destination))。", prefs: Prefs(), rules: []), "打开新版应用包。")
        }
    }

    func testMultipleLinksPreserveLabelsAndParagraphs() {
        let raw = "查看[**应用包**](/build/念.app)和[说明](https://example.com)。\n\n测试通过。"
        XCTAssertEqual(Dictionary_.apply(raw, prefs: Prefs(), rules: []), "查看应用包和说明。\n\n测试通过。")
    }

    func testPlainTextAndOrdinaryParenthesesArePreserved() {
        let raw = "测试通过（119 项）。文件名是念.app，保留 [备注] 和 (说明)。"
        XCTAssertEqual(Dictionary_.apply(raw, prefs: Prefs(), rules: []), raw)
    }

    func testDisablingMarkdownCleanupPreservesOriginalLink() {
        var prefs = Prefs()
        prefs.stripMarkdown = false
        let raw = "[新版应用包](/Users/reader/build/念.app)"
        XCTAssertEqual(Dictionary_.apply(raw, prefs: prefs, rules: []), raw)
    }
}
