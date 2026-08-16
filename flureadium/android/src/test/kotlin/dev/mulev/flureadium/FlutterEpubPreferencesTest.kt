package dev.mulev.flureadium

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.Spread
import org.readium.r2.navigator.preferences.TextAlign
import org.readium.r2.shared.ExperimentalReadiumApi

/**
 * Unit tests for [epubPreferencesFromMap], focused on typography and layout
 * fields (`lineHeight`, `publisherStyles`, `columnCount`, `spread`).
 */
@OptIn(ExperimentalReadiumApi::class)
internal class FlutterEpubPreferencesTest {

    @Test
    fun fromMap_parsesLineHeightAndPublisherStyles() {
        val map = mapOf(
            "lineHeight" to "1.5",
            "publisherStyles" to "false",
        )

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertEquals(1.5, prefs.lineHeight)
        assertEquals(false, prefs.publisherStyles)
    }

    @Test
    fun fromMap_missingFieldsFallBackToDefaults() {
        val defaults = EpubPreferences(lineHeight = 1.2, publisherStyles = true)

        val prefs = epubPreferencesFromMap(emptyMap(), defaults = defaults)

        assertEquals(1.2, prefs.lineHeight)
        assertEquals(true, prefs.publisherStyles)
    }

    @Test
    fun fromMap_missingFieldsAndNoDefaultsAreNull() {
        val prefs = epubPreferencesFromMap(emptyMap(), defaults = null)

        assertNull(prefs.lineHeight)
        assertNull(prefs.publisherStyles)
    }

    @Test
    fun fromMap_mapValuesOverrideDefaults() {
        val defaults = EpubPreferences(lineHeight = 1.2, publisherStyles = true)
        val map = mapOf(
            "lineHeight" to "2.0",
            "publisherStyles" to "false",
        )

        val prefs = epubPreferencesFromMap(map, defaults = defaults)

        assertEquals(2.0, prefs.lineHeight)
        assertEquals(false, prefs.publisherStyles)
    }

    @Test
    fun fromMap_invalidLineHeightFallsBackToDefault() {
        val defaults = EpubPreferences(lineHeight = 1.2)
        val map = mapOf("lineHeight" to "not-a-number")

        val prefs = epubPreferencesFromMap(map, defaults = defaults)

        assertEquals(1.2, prefs.lineHeight)
    }

    @Test
    fun fromMap_missingFontFamilyLeavesNull() {
        val map = mapOf(
            "lineHeight" to "1.5",
            "publisherStyles" to "false",
        )

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertNull(prefs.fontFamily)
        assertEquals(1.5, prefs.lineHeight)
        assertEquals(false, prefs.publisherStyles)
    }

    @Test
    fun fromMap_parsesColumnCountAndSpread() {
        val map = mapOf(
            "columnCount" to "2",
            "spread" to "always",
        )

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertEquals(ColumnCount.TWO, prefs.columnCount)
        assertEquals(Spread.ALWAYS, prefs.spread)
    }

    @Test
    fun fromMap_defaultsColumnCountToOneAndSpreadToNever() {
        val prefs = epubPreferencesFromMap(emptyMap(), defaults = null)

        assertEquals(ColumnCount.ONE, prefs.columnCount)
        assertEquals(Spread.NEVER, prefs.spread)
    }

    @Test
    fun fromMap_columnCountAndSpreadFallBackToDefaults() {
        val defaults = EpubPreferences(
            columnCount = ColumnCount.TWO,
            spread = Spread.ALWAYS,
        )

        val prefs = epubPreferencesFromMap(emptyMap(), defaults = defaults)

        assertEquals(ColumnCount.TWO, prefs.columnCount)
        assertEquals(Spread.ALWAYS, prefs.spread)
    }

    @Test
    fun fromMap_parsesAutoColumnCountAndSpread() {
        val map = mapOf(
            "columnCount" to "auto",
            "spread" to "auto",
        )

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertEquals(ColumnCount.AUTO, prefs.columnCount)
        assertEquals(Spread.AUTO, prefs.spread)
    }

    @Test
    fun fromMap_invalidColumnCountFallsBackToDefaultOne() {
        val map = mapOf("columnCount" to "three")

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertEquals(ColumnCount.ONE, prefs.columnCount)
    }

    @Test
    fun fromMap_parsesTextAlignLeft() {
        val map = mapOf("textAlign" to "left")

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertEquals(TextAlign.LEFT, prefs.textAlign)
    }

    @Test
    fun fromMap_parsesTextAlignJustify() {
        val map = mapOf("textAlign" to "justify")

        val prefs = epubPreferencesFromMap(map, defaults = null)

        assertEquals(TextAlign.JUSTIFY, prefs.textAlign)
    }

    @Test
    fun fromMap_missingTextAlignIsNull() {
        val prefs = epubPreferencesFromMap(emptyMap(), defaults = null)

        assertNull(prefs.textAlign)
    }

    @Test
    fun fromMap_textAlignFallsBackToDefaults() {
        val defaults = EpubPreferences(textAlign = TextAlign.JUSTIFY)

        val prefs = epubPreferencesFromMap(emptyMap(), defaults = defaults)

        assertEquals(TextAlign.JUSTIFY, prefs.textAlign)
    }

    @Test
    fun fromMap_invalidTextAlignFallsBackToDefault() {
        val defaults = EpubPreferences(textAlign = TextAlign.LEFT)
        val map = mapOf("textAlign" to "not-an-align")

        val prefs = epubPreferencesFromMap(map, defaults = defaults)

        assertEquals(TextAlign.LEFT, prefs.textAlign)
    }
}
