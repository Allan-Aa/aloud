import ApplicationServices
import XCTest
@testable import Aloud

final class SelectionTests: XCTestCase {
    func testReadsSelectionFromFocusedElementWithoutReadingItsValue() throws {
        let focused = AXUIElementCreateApplication(101)
        let result = try Selection.selectedText(startingAt: focused) { name, _ in
            XCTAssertEqual(name, kAXSelectedTextAttribute)
            return "  first line\n第二行  " as CFString
        }
        XCTAssertEqual(result, "  first line\n第二行  ")
    }

    func testFindsWebSelectionOnAncestorWhenFocusedControlHasNone() throws {
        let focused = AXUIElementCreateApplication(101)
        let webArea = AXUIElementCreateApplication(102)
        let result = try Selection.selectedText(startingAt: focused) { name, element in
            if element == focused {
                return name == kAXParentAttribute ? webArea : "" as CFString
            }
            XCTAssertEqual(element, webArea)
            XCTAssertEqual(name, kAXSelectedTextAttribute)
            return "selected across multiple paragraphs" as CFString
        }
        XCTAssertEqual(result, "selected across multiple paragraphs")
    }

    func testMissingAndWhitespaceSelectionsReturnNilWithoutUsingFullText() throws {
        let focused = AXUIElementCreateApplication(101)
        for selection: String? in ["", " \n\t"] {
            let result = try Selection.selectedText(startingAt: focused) { name, _ in
                switch name {
                case kAXSelectedTextAttribute: return selection.map { $0 as CFString }
                case kAXParentAttribute: return nil
                default: XCTFail("Must not read the entire message or control value"); return "wrong text" as CFString
                }
            }
            XCTAssertNil(result)
        }
    }

    func testCyclicAccessibilityParentsDoNotLoop() throws {
        let focused = AXUIElementCreateApplication(101)
        var reads = 0
        XCTAssertThrowsError(try Selection.selectedText(startingAt: focused) { name, _ in
            reads += 1
            return name == kAXParentAttribute ? focused : nil
        })
        XCTAssertEqual(reads, 2)
    }
    func testUnsupportedAXSelectionIsDistinctFromEmptySelection() {
        let focused = AXUIElementCreateApplication(101)
        XCTAssertThrowsError(try Selection.selectedText(startingAt: focused) { _, _ in nil }) { error in
            guard case Selection.Failure.selectionUnavailable = error else { return XCTFail("Wrong failure") }
        }
    }

    func testCopyFallbackReturnsSelectionAndOnlyTimeoutMeansNoSelection() async throws {
        let selected = try await Selection.copyIfPresent { "selected through copy" }
        XCTAssertEqual(selected, "selected through copy")
        let absent = try await Selection.copyIfPresent { throw PasteboardTransportError.timeout }
        XCTAssertNil(absent)
        for failure in [PasteboardTransportError.ownershipLost, .restoreFailed] {
            do {
                _ = try await Selection.copyIfPresent { throw failure }
                XCTFail("Clipboard failure must not fall back to latest reply")
            } catch { XCTAssertEqual(error as? PasteboardTransportError, failure) }
        }
        do {
            _ = try await Selection.copyIfPresent { throw CancellationError() }
            XCTFail("Cancellation must not fall back to latest reply")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

}
