package dev.mulev.flureadium.navigators

import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.html.cssSelector
import org.readium.r2.shared.publication.html.domRange
import kotlin.math.abs

/**
 * Android EPUB restore helpers.
 *
 * Progression is approximate (reflow, fonts, WebView geometry). A 1% chapter
 * delta can be a full page in a long resource, so it must not override an
 * element anchor ([cssSelector] / [domRange]).
 */
internal object EpubRestore {
    /** Skip a progression-only re-scroll when already this close (JS noise). */
    const val PROGRESSION_SKIP_THRESHOLD = 0.01

    /** After first element scroll, wait for layout/fonts then scroll again. */
    const val ELEMENT_REANCHOR_DELAY_MS = 250L

    fun hasElementAnchor(locations: Locator.Locations): Boolean {
        return locations.domRange != null || !locations.cssSelector.isNullOrBlank()
    }

    /**
     * Whether [goToLocator] should skip [scrollToLocations].
     *
     * Never skip when the target has a CSS/DOM anchor. Progression-only
     * locators still skip inside [PROGRESSION_SKIP_THRESHOLD] so a no-op
     * scroll cannot rewrite StateFlow from bounding-rect jitter.
     */
    fun shouldSkipProgressionScroll(
        currentProgression: Double?,
        targetProgression: Double?,
        hasElementAnchor: Boolean,
    ): Boolean {
        if (hasElementAnchor) return false
        if (currentProgression == null || targetProgression == null) return false
        return abs(currentProgression - targetProgression) < PROGRESSION_SKIP_THRESHOLD
    }
}
