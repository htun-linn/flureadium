//
//  ReadiumExtensionsMappingTests.swift
//  flureadiumTests
//
//  Tests that EPUBPreferences and PDFPreferences extensions correctly map
//  Readium-specific keys from the channel arguments.
//  Navigation UX config is now handled separately via setNavigationConfig.
//

import XCTest
@testable import flureadium
import ReadiumNavigator

final class ReadiumExtensionsMappingTests: XCTestCase {

    // MARK: - EPUBPreferences.init(fromMap:) — Readium key mapping

    func testEPUBPreferencesFromMapMapsBackgroundColor() {
        let map: [String: String] = ["backgroundColor": "#000000"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertNotNil(prefs.backgroundColor)
    }

    func testEPUBPreferencesFromMapMapsTextColor() {
        let map: [String: String] = ["textColor": "#ffffff"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertNotNil(prefs.textColor)
    }

    func testEPUBPreferencesFromMapMapsFontSize() {
        let map: [String: String] = ["fontSize": "1.5"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.fontSize, 1.5)
    }

    func testEPUBPreferencesFromMapMapsVerticalScroll() {
        let map: [String: String] = ["verticalScroll": "true"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.scroll, true)
    }

    func testEPUBPreferencesFromMapMapsLineHeight() {
        let map: [String: String] = ["lineHeight": "1.5"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.lineHeight, 1.5)
    }

    func testEPUBPreferencesFromMapMapsPublisherStyles() {
        let map: [String: String] = ["publisherStyles": "false"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.publisherStyles, false)
    }

    func testEPUBPreferencesFromMapMapsMultipleReadiumKeys() {
        let map: [String: String] = [
            "backgroundColor": "#1a1a1a",
            "textColor": "#eeeeee",
            "fontSize": "1.2",
            "fontWeight": "0.8",
            "verticalScroll": "false",
            "lineHeight": "1.5",
            "publisherStyles": "false",
        ]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertNotNil(prefs.backgroundColor)
        XCTAssertNotNil(prefs.textColor)
        XCTAssertEqual(prefs.fontSize, 1.2)
        XCTAssertEqual(prefs.fontWeight, 0.8)
        XCTAssertEqual(prefs.scroll, false)
        XCTAssertEqual(prefs.lineHeight, 1.5)
        XCTAssertEqual(prefs.publisherStyles, false)
    }

    func testEPUBPreferencesFromMapEmptyMapProducesDefaultPrefs() {
        let map: [String: String] = [:]
        let prefs = EPUBPreferences(fromMap: map)
        // Most optional fields remain nil when map is empty…
        XCTAssertNil(prefs.backgroundColor)
        XCTAssertNil(prefs.textColor)
        XCTAssertNil(prefs.fontSize)
        XCTAssertNil(prefs.scroll)
        XCTAssertNil(prefs.lineHeight)
        XCTAssertNil(prefs.publisherStyles)
        XCTAssertNil(prefs.fontFamily)
        // …except column/spread, which default to single-page layout.
        XCTAssertEqual(prefs.columnCount, .one)
        XCTAssertEqual(prefs.spread, .never)
    }

    func testEPUBPreferencesFromMapMapsColumnCountAndSpread() {
        let map: [String: String] = [
            "columnCount": "2",
            "spread": "always",
        ]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.columnCount, .two)
        XCTAssertEqual(prefs.spread, .always)
    }

    func testEPUBPreferencesFromMapMapsAutoColumnCountAndSpread() {
        let map: [String: String] = [
            "columnCount": "auto",
            "spread": "auto",
        ]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.columnCount, .auto)
        XCTAssertEqual(prefs.spread, .auto)
    }

    func testEPUBPreferencesFromMapOmitsFontFamilyKeepsPublisherFonts() {
        // Line height + publisherStyles without a fontFamily key: Readium should
        // leave the publication's typeface alone while applying line height.
        let map: [String: String] = [
            "lineHeight": "1.5",
            "publisherStyles": "false",
        ]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertNil(prefs.fontFamily)
        XCTAssertEqual(prefs.lineHeight, 1.5)
        XCTAssertEqual(prefs.publisherStyles, false)
    }

    func testEPUBPreferencesFromMapMapsTextAlignLeft() {
        let map: [String: String] = ["textAlign": "left"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.textAlign, .left)
    }

    func testEPUBPreferencesFromMapMapsTextAlignJustify() {
        let map: [String: String] = ["textAlign": "justify"]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertEqual(prefs.textAlign, .justify)
    }

    func testEPUBPreferencesFromMapOmitsTextAlignWhenUnset() {
        let map: [String: String] = [
            "lineHeight": "1.5",
            "publisherStyles": "false",
        ]
        let prefs = EPUBPreferences(fromMap: map)
        XCTAssertNil(prefs.textAlign)
    }

    // MARK: - PDFPreferences.init(fromMap:) — Readium key mapping

    func testPDFPreferencesFromMapMapsFitWidth() {
        let map: [String: Any] = ["fit": "width"]
        let prefs = PDFPreferences(fromMap: map)
        XCTAssertEqual(prefs.scroll, true)
    }

    func testPDFPreferencesFromMapMapsFitContain() {
        let map: [String: Any] = ["fit": "contain"]
        let prefs = PDFPreferences(fromMap: map)
        XCTAssertEqual(prefs.scroll, false)
    }

    func testPDFPreferencesFromMapMapsScrollModeVertical() {
        let map: [String: Any] = ["scrollMode": "vertical"]
        let prefs = PDFPreferences(fromMap: map)
        XCTAssertEqual(prefs.scrollAxis, .vertical)
    }

    func testPDFPreferencesFromMapMapsScrollModeHorizontal() {
        let map: [String: Any] = ["scrollMode": "horizontal"]
        let prefs = PDFPreferences(fromMap: map)
        XCTAssertEqual(prefs.scrollAxis, .horizontal)
    }

    func testPDFPreferencesFromMapMapsMultipleReadiumKeys() {
        let map: [String: Any] = [
            "fit": "width",
            "scrollMode": "vertical",
        ]
        let prefs = PDFPreferences(fromMap: map)
        XCTAssertEqual(prefs.scroll, true)
        XCTAssertEqual(prefs.scrollAxis, .vertical)
    }

    func testPDFPreferencesFromMapEmptyMapProducesDefaultPrefs() {
        let map: [String: Any] = [:]
        let prefs = PDFPreferences(fromMap: map)
        XCTAssertNil(prefs.scroll)
        XCTAssertNil(prefs.scrollAxis)
    }

    func testMboCssAlignMapsJustifyAndLeft() {
        XCTAssertEqual(mboCssAlign(.justify), "justify")
        XCTAssertEqual(mboCssAlign(.left), "left")
        XCTAssertEqual(mboCssAlign(nil), "default")
    }

    func testPreferencesWithoutReadiumTextAlignClearsTextAlignOnly() {
        let prefs = EPUBPreferences(fromMap: [
            "lineHeight": "1.5",
            "publisherStyles": "false",
            "textAlign": "justify",
        ])
        XCTAssertEqual(prefs.textAlign, .justify)
        let stripped = preferencesWithoutReadiumTextAlign(prefs)
        XCTAssertNil(stripped.textAlign)
        XCTAssertEqual(stripped.lineHeight, 1.5)
        XCTAssertEqual(stripped.publisherStyles, false)
        XCTAssertEqual(prefs.textAlign, .justify)
    }
}
