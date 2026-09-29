import XCTest
@testable import flureadium

final class EpubEditingActionsTests: XCTestCase {

    func testEpubEditingActionsContainsCopy() {
        XCTAssertTrue(
            ReadiumReaderView.epubEditingActions.contains(.copy),
            "editingActions must include .copy so users can copy selected text"
        )
    }

    func testEpubEditingActionsContainsHighlightAndNote() {
        XCTAssertTrue(
            ReadiumReaderView.epubEditingActions.contains(ReadiumReaderView.highlightEditingAction),
            "editingActions must include Highlight"
        )
        XCTAssertTrue(
            ReadiumReaderView.epubEditingActions.contains(ReadiumReaderView.noteEditingAction),
            "editingActions must include Add note"
        )
    }

    func testEpubEditingActionsCountIsThree() {
        XCTAssertEqual(
            ReadiumReaderView.epubEditingActions.count,
            3,
            "editingActions must contain Copy, Highlight, and Add note"
        )
    }
}
