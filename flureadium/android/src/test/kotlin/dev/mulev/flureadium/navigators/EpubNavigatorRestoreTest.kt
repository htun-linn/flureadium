package dev.mulev.flureadium.navigators

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.readium.r2.shared.util.Url
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

/**
 * Tests for EPUB restore behavior.
 *
 * Progression-only locators still skip a no-op scroll inside 1% so JS
 * bounding-rect jitter cannot rewrite StateFlow. Element locators
 * (cssSelector / domRange) must never be skipped — 1% of a long chapter
 * is a full page.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
internal class EpubNavigatorRestoreTest {

    @Test
    fun progressionOnly_withinThreshold_shouldSkipScroll() {
        assertTrue(
            EpubRestore.shouldSkipProgressionScroll(0.3170654, 0.3170654, hasElementAnchor = false),
        )
    }

    @Test
    fun progressionOnly_smallJsDrift_shouldSkipScroll() {
        assertTrue(
            EpubRestore.shouldSkipProgressionScroll(0.3170654, 0.3150764, hasElementAnchor = false),
        )
    }

    @Test
    fun progressionOnly_largeDifference_shouldScroll() {
        assertFalse(
            EpubRestore.shouldSkipProgressionScroll(0.3170654, 0.5342220, hasElementAnchor = false),
        )
    }

    @Test
    fun progressionOnly_nullValues_shouldScroll() {
        assertFalse(
            EpubRestore.shouldSkipProgressionScroll(null, 0.317, hasElementAnchor = false),
        )
    }

    @Test
    fun elementAnchor_evenWithinOnePercent_shouldScroll() {
        assertFalse(
            EpubRestore.shouldSkipProgressionScroll(0.423, 0.425, hasElementAnchor = true),
        )
    }

    @Test
    fun elementAnchor_exactProgressionMatch_shouldScroll() {
        assertFalse(
            EpubRestore.shouldSkipProgressionScroll(0.423, 0.423, hasElementAnchor = true),
        )
    }

    @Test
    fun locatorHref_sameResource_shouldBeEquivalent() {
        val href1 = Url("OEBPS/chapter01.xhtml")!!
        val href2 = Url("OEBPS/chapter01.xhtml")!!
        assertTrue(href1.isEquivalent(href2))
    }

    @Test
    fun locatorHref_differentResource_shouldNotBeEquivalent() {
        val href1 = Url("OEBPS/chapter01.xhtml")!!
        val href2 = Url("OEBPS/chapter02.xhtml")!!
        assertFalse(href1.isEquivalent(href2))
    }
}
