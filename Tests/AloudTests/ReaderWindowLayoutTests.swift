import AppKit
import SwiftUI
import XCTest
@testable import Aloud

@MainActor
final class ReaderWindowLayoutTests: XCTestCase {
    func testSidebarResizesWindowWithoutReplacingEditorOrChangingHeight() throws {
        let route = ReaderWindowRoute()
        var text = "Draft remains here"
        let host = NSHostingView(rootView: ReaderWindowLayout(route: route) {
            TextEditor(text: Binding(get: { text }, set: { text = $0 }))
        } settings: {
            Text("Settings").frame(maxHeight: .infinity)
        })
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 610, height: 740),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 610, height: 740))
        defer { window.close() }
        settle(host)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        editor.insertText(" preserved", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        let draft = text
        let originalHeight = try XCTUnwrap(window.contentView).bounds.height
        let originalX = window.frame.minX

        for _ in 0..<2 {
            route.present()
            settle(host)
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, 960.5, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.height, originalHeight, accuracy: 1)
            route.dismiss()
            settle(host)
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, 610, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.height, originalHeight, accuracy: 1)
            XCTAssertEqual(window.frame.minX, originalX, accuracy: 1)
            XCTAssertTrue(descendants(host).contains { $0 === editor })
            XCTAssertEqual(text, draft)
        }
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
