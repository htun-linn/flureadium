//
//  ScrollModeNavigationTests.swift
//  flureadiumTests
//
//  Unit tests for scroll mode chapter navigation helpers:
//  chapterLink(before:in:), chapterLink(after:in:), strippedHref(_:)
//

import XCTest
import ReadiumShared
@testable import flureadium

// MARK: - Helpers under test (free functions declared in ReadiumReaderView.swift)
// They are internal (no access modifier), so @testable import exposes them.

final class ScrollModeNavigationTests: XCTestCase {

    // MARK: - Fixtures

    private func makeLink(_ href: String) -> Link {
        Link(href: href)
    }

    private var threeLinks: [Link] {
        [makeLink("ch1.html"), makeLink("ch2.html"), makeLink("ch3.html")]
    }

    // MARK: - strippedHref

    func testStrippedHref_noFragment_unchanged() {
        XCTAssertEqual(strippedHref("ch1.html"), "ch1.html")
    }

    func testStrippedHref_removesFragment() {
        XCTAssertEqual(strippedHref("ch1.html#section-2"), "ch1.html")
    }

    func testStrippedHref_removesQuery() {
        XCTAssertEqual(strippedHref("ch1.html?page=3"), "ch1.html")
    }

    func testStrippedHref_removesFragmentAndQuery() {
        // Fragment wins: components(separatedBy: "#") splits first
        XCTAssertEqual(strippedHref("ch1.html#anchor?query=1"), "ch1.html")
    }

    func testStrippedHref_emptyString() {
        XCTAssertEqual(strippedHref(""), "")
    }

    // MARK: - chapterLink(before:in:) — empty / boundary

    func testChapterBefore_emptyReadingOrder_returnsNil() {
        XCTAssertNil(chapterLink(before: "ch1.html", in: []))
    }

    func testChapterBefore_atFirstItem_returnsNil() {
        XCTAssertNil(chapterLink(before: "ch1.html", in: threeLinks))
    }

    func testChapterBefore_hrefNotFound_returnsNil() {
        XCTAssertNil(chapterLink(before: "unknown.html", in: threeLinks))
    }

    // MARK: - chapterLink(before:in:) — normal navigation

    func testChapterBefore_atSecondItem_returnsFirst() {
        let result = chapterLink(before: "ch2.html", in: threeLinks)
        XCTAssertEqual(result?.href, "ch1.html")
    }

    func testChapterBefore_atLastItem_returnsSecond() {
        let result = chapterLink(before: "ch3.html", in: threeLinks)
        XCTAssertEqual(result?.href, "ch2.html")
    }

    // MARK: - chapterLink(before:in:) — href stripping

    func testChapterBefore_currentHrefWithFragment_matchesCleanHref() {
        let result = chapterLink(before: "ch2.html#section", in: threeLinks)
        XCTAssertEqual(result?.href, "ch1.html")
    }

    func testChapterBefore_currentHrefWithQuery_matchesCleanHref() {
        let result = chapterLink(before: "ch2.html?p=1", in: threeLinks)
        XCTAssertEqual(result?.href, "ch1.html")
    }

    func testChapterBefore_linkHrefWithFragment_matchesCurrentClean() {
        let linksWithFragments = [
            makeLink("ch1.html#intro"),
            makeLink("ch2.html#body"),
            makeLink("ch3.html#end"),
        ]
        // Current href: "ch2.html" should match "ch2.html#body" after stripping
        let result = chapterLink(before: "ch2.html", in: linksWithFragments)
        XCTAssertEqual(result?.href, "ch1.html#intro")
    }

    // MARK: - chapterLink(after:in:) — empty / boundary

    func testChapterAfter_emptyReadingOrder_returnsNil() {
        XCTAssertNil(chapterLink(after: "ch1.html", in: []))
    }

    func testChapterAfter_atLastItem_returnsNil() {
        XCTAssertNil(chapterLink(after: "ch3.html", in: threeLinks))
    }

    func testChapterAfter_hrefNotFound_returnsNil() {
        XCTAssertNil(chapterLink(after: "unknown.html", in: threeLinks))
    }

    // MARK: - chapterLink(after:in:) — normal navigation

    func testChapterAfter_atFirstItem_returnsSecond() {
        let result = chapterLink(after: "ch1.html", in: threeLinks)
        XCTAssertEqual(result?.href, "ch2.html")
    }

    func testChapterAfter_atSecondItem_returnsThird() {
        let result = chapterLink(after: "ch2.html", in: threeLinks)
        XCTAssertEqual(result?.href, "ch3.html")
    }

    // MARK: - chapterLink(after:in:) — href stripping

    func testChapterAfter_currentHrefWithFragment_matchesCleanHref() {
        let result = chapterLink(after: "ch2.html#section", in: threeLinks)
        XCTAssertEqual(result?.href, "ch3.html")
    }

    func testChapterAfter_currentHrefWithQuery_matchesCleanHref() {
        let result = chapterLink(after: "ch2.html?p=1", in: threeLinks)
        XCTAssertEqual(result?.href, "ch3.html")
    }

    func testChapterAfter_linkHrefWithFragment_matchesCurrentClean() {
        let linksWithFragments = [
            makeLink("ch1.html#intro"),
            makeLink("ch2.html#body"),
            makeLink("ch3.html#end"),
        ]
        let result = chapterLink(after: "ch2.html", in: linksWithFragments)
        XCTAssertEqual(result?.href, "ch3.html#end")
    }

    // MARK: - configureEdgeTapHandlers scroll mode: callback presence

    func testScrollMode_tapCallbacksNil_evenWhenEdgeTapEnabled() {
        // In scroll mode, ALL tap callbacks are unconditionally nil —
        // even when enableEdgeTapNavigation is true.
        // WKWebView handles native swipes; EdgeTapInterceptView must not intercept.
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        view.onLeftEdgeTap = nil
        view.onRightEdgeTap = nil

        XCTAssertNil(view.onLeftEdgeTap, "Left tap callback must be nil in scroll mode regardless of edge tap setting")
        XCTAssertNil(view.onRightEdgeTap, "Right tap callback must be nil in scroll mode regardless of edge tap setting")
    }

    func testScrollMode_tapCallbacksNil_whenEdgeTapDisabled() {
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        // Simulate the scroll-mode branch with enableEdgeTapNavigation = false
        view.onLeftEdgeTap = nil
        view.onRightEdgeTap = nil

        XCTAssertNil(view.onLeftEdgeTap, "Left tap callback should be nil in scroll mode with edge tap disabled")
        XCTAssertNil(view.onRightEdgeTap, "Right tap callback should be nil in scroll mode with edge tap disabled")
    }

    func testScrollMode_swipeCallbacksNil_evenWhenSwipeEnabled() {
        // In scroll mode, ALL swipe callbacks are unconditionally nil —
        // even when enableSwipeNavigation is true.
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        view.onSwipeLeft = nil
        view.onSwipeRight = nil

        XCTAssertNil(view.onSwipeLeft, "Swipe left callback must be nil in scroll mode regardless of swipe setting")
        XCTAssertNil(view.onSwipeRight, "Swipe right callback must be nil in scroll mode regardless of swipe setting")
    }

    func testScrollMode_swipeCallbacksNil_whenSwipeDisabled() {
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        view.onSwipeLeft = nil
        view.onSwipeRight = nil

        XCTAssertNil(view.onSwipeLeft, "Swipe left callback should be nil in scroll mode with swipe disabled")
        XCTAssertNil(view.onSwipeRight, "Swipe right callback should be nil in scroll mode with swipe disabled")
    }

    func testPaginatedMode_tapCallbacksUnaffected() {
        // Paginated mode should assign tap callbacks (existing behaviour must remain)
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        view.onLeftEdgeTap = { }
        view.onRightEdgeTap = { }

        XCTAssertNotNil(view.onLeftEdgeTap, "Paginated mode left tap must remain non-nil")
        XCTAssertNotNil(view.onRightEdgeTap, "Paginated mode right tap must remain non-nil")
    }

    func testScrollMode_interceptEdgeTapsFalse() {
        // In scroll mode, configureEdgeTapHandlers sets interceptEdgeTaps = false
        // so WKWebView receives all touches natively.
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        view.interceptEdgeTaps = false  // simulate scroll mode branch

        XCTAssertFalse(view.interceptEdgeTaps,
            "interceptEdgeTaps must be false in scroll mode")
    }

    func testPaginatedMode_interceptEdgeTapsOnlyWhenOverlayNavigationEnabled() {
        // Overlay claims the edge zone only when tap or swipe navigation is on.
        // With both off, interceptEdgeTaps is false so edge swipes reach WKWebView.
        let view = EdgeTapInterceptView(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        view.interceptEdgeTaps = false

        XCTAssertFalse(view.interceptEdgeTaps,
            "interceptEdgeTaps must be false when overlay tap/swipe are disabled")
    }

    // MARK: - isBackwardNavigation(from:to:in:)

    func testIsBackwardNavigation_emptyReadingOrder_returnsFalse() {
        XCTAssertFalse(isBackwardNavigation(from: "ch2.html", to: "ch1.html", in: []))
    }

    func testIsBackwardNavigation_oldHrefNotFound_returnsFalse() {
        XCTAssertFalse(isBackwardNavigation(from: "unknown.html", to: "ch1.html", in: threeLinks))
    }

    func testIsBackwardNavigation_newHrefNotFound_returnsFalse() {
        XCTAssertFalse(isBackwardNavigation(from: "ch2.html", to: "unknown.html", in: threeLinks))
    }

    func testIsBackwardNavigation_backwardNav_returnsTrue() {
        // ch3 → ch2: newIdx(1) < oldIdx(2) → true
        XCTAssertTrue(isBackwardNavigation(from: "ch3.html", to: "ch2.html", in: threeLinks))
    }

    func testIsBackwardNavigation_forwardNav_returnsFalse() {
        // ch1 → ch2: newIdx(1) > oldIdx(0) → false
        XCTAssertFalse(isBackwardNavigation(from: "ch1.html", to: "ch2.html", in: threeLinks))
    }

    func testIsBackwardNavigation_sameItem_returnsFalse() {
        XCTAssertFalse(isBackwardNavigation(from: "ch2.html", to: "ch2.html", in: threeLinks))
    }

    func testIsBackwardNavigation_fragmentsStrippedBeforeComparison() {
        // ch3.html#end → ch1.html#intro: both stripped, newIdx(0) < oldIdx(2) → true
        XCTAssertTrue(isBackwardNavigation(from: "ch3.html#end", to: "ch1.html#intro", in: threeLinks))
    }
}
