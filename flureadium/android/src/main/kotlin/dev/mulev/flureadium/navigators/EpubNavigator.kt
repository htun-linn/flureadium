package dev.mulev.flureadium.navigators

import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import androidx.fragment.app.FragmentManager
import androidx.fragment.app.commitNow
import dev.mulev.flureadium.FlutterNavigationConfig
import dev.mulev.flureadium.MboParagraphAlign
import dev.mulev.flureadium.ReadiumReaderWidget.Companion.NAVIGATOR_FRAGMENT_TAG
import dev.mulev.flureadium.canScroll
import dev.mulev.flureadium.withoutReadiumTextAlign
import dev.mulev.flureadium.fragments.EpubReaderFragment
import dev.mulev.flureadium.jsonDecode
import dev.mulev.flureadium.models.EpubReaderViewModel
import dev.mulev.flureadium.throttleLatest
import dev.mulev.flureadium.withScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.DecorableNavigator
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.epub.EpubPreferencesEditor
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.AbsoluteUrl
import kotlin.time.Duration.Companion.milliseconds

private const val TAG = "EpubNavigator"
private const val currentVisualCurrentLocatorKey = "currentVisualCurrentLocator"
private const val epubPreferencesKey = "epubPreferences"

/**
 * EpubNavigator is a wrapper around the EpubReaderFragment and provides methods to interact with it.
 * It also listens to events from the fragment and forwards them to the VisualListener.
 */
@ExperimentalCoroutinesApi
@OptIn(ExperimentalReadiumApi::class)
class EpubNavigator : BaseNavigator, EpubReaderFragment.Listener {
    private val initialPreferences: EpubPreferences

    constructor(
        publication: Publication,
        initialLocator: Locator?,
        visualListener: VisualListener,
        initialPreferences: EpubPreferences = EpubPreferences()
    ) : super(publication, initialLocator) {
        this.initialPreferences = initialPreferences
        this.visualListener = visualListener
        MboParagraphAlign.setFrom(initialPreferences.textAlign)

        this.state[currentVisualCurrentLocatorKey] = initialLocator
        this.state[epubPreferencesKey] = initialPreferences
    }

    /**
     * A VisualListener is used to listen to events from the Visual navigators like EpubNavigator.
     */
    interface VisualListener {
        /**
         * Called when a page has loaded. Note: not necessarily the visible content, since
         * the Readium Navigator preloads neighboring charters.
         */
        fun onPageLoaded()

        /**
         * Called when the current page has changed. Can be a new file or a new page in the
         * same file.
         */
        fun onPageChanged(pageIndex: Int, totalPages: Int, locator: Locator)

        /**
         * Called when an external link has been tapped.
         */
        fun onExternalLinkActivated(url: AbsoluteUrl)

        /** Called when a user taps an EPUB decoration. */
        fun onDecorationTapped(id: String, locator: Locator)

        /**
         * Called when the current locator has changed.
         */
        fun onVisualCurrentLocationChanged(locator: Locator)

        /**
         * Called when the visual reader is ready.
         */
        fun onVisualReaderIsReady()
    }

    val visualListener: VisualListener

    /**
     * EpubReaderFragment instance used as navigator.
     */
    private var epubNavigator: EpubReaderFragment? = null

    /**
     * Tracks which fragment instance we've subscribed to, to detect fragment recreation.
     */
    private var subscribedFragmentInstance: EpubReaderFragment? = null

    /**
     * Editor to modify EPUB preferences.
     */
    private var editor: EpubPreferencesEditor? = null

    private val annotationDecorationListener = object : DecorableNavigator.Listener {
        override fun onDecorationActivated(
            event: DecorableNavigator.OnActivatedEvent
        ): Boolean {
            if (event.group != ANNOTATION_DECORATION_GROUP) return false
            visualListener.onDecorationTapped(event.decoration.id, event.decoration.locator)
            return true
        }
    }

    /**
     * Pending scroll target to be applied when the page is loaded.
     */
    var pendingScrollToLocations: Locator.Locations? = null

    /**
     * Current EPUB preferences.
     */
    val preferences: EpubPreferences?
        get() = editor?.preferences

    /**
     * Current locator in the EPUB navigator.
     */
    val currentLocator
        get() = epubNavigator?.currentLocator

    /**
     * Checks when the fragment starts and is safe to use.
     */
    private val navigatorStarted
        get() = epubNavigator!!.started

    /**
     * Whether the EPUB navigator is in vertical scroll mode.
     */
    private val isVerticalScroll: Boolean
        get() {
            return editor?.preferences?.scroll ?: false
        }

    override suspend fun initNavigator() {
        pendingScrollToLocations =
            initialLocator?.locations?.let { locations ->
                if (canScroll(locations)) locations else null
            }

        val readiumPrefs = initialPreferences.withoutReadiumTextAlign()
        MboParagraphAlign.setFrom(initialPreferences.textAlign)
        epubNavigator = EpubReaderFragment().apply {
            vm = EpubReaderViewModel().apply {
                navigatorFactory = EpubNavigatorFactory(publication)
                locator = this@EpubNavigator.initialLocator
                preferences = readiumPrefs

                editor =
                    navigatorFactory!!.createPreferencesEditor(readiumPrefs)
            }
            listener = this@EpubNavigator
        }
    }

    /**
     * Attach the EPUB navigator fragment to the given FragmentManager and ViewGroup.
     */
    fun attachNavigator(fragmentManager: FragmentManager, viewGroup: ViewGroup) {
        val navigator = epubNavigator ?: return
        mainScope.launch {
            fragmentManager.commitNow {
                add(viewGroup, navigator, NAVIGATOR_FRAGMENT_TAG)
            }
        }
    }

    /**
     * Go to a specific locator in the EPUB navigator, this does not scroll to the locator position.
     */
    suspend fun go(locator: Locator, animated: Boolean): Boolean {
        val navigator = epubNavigator
        if (navigator == null) {
            Log.d(TAG, "::go - epubNavigator is null!")
            return false
        }

        return withScope(mainScope) {
            afterFragmentStarted()
            if (!navigator.go(locator, animated)) {
                Log.w(TAG, "::go -  FAILED!")
                return@withScope false
            }

            Log.d(TAG, "::go - returned true")

            return@withScope true
        }
    }

    /**
     * Update EPUB navigator preferences.
     */
    fun updatePreferences(preferences: EpubPreferences) {
        val currentLocatorValue = epubNavigator?.currentLocator?.value
        Log.d(TAG, "::updatePreferences - currentLocator BEFORE=${currentLocatorValue?.let {
            "href=${it.href}, prog=${it.locations.progression}"
        } ?: "null"}, preferences=$preferences")

        try {
            // Never pass textAlign to Readium: --USER__textAlign forces every
            // p { text-align: inherit !important } and clobbers publisher
            // center/right. We apply left/justify ourselves via --MBO__paraAlign.
            MboParagraphAlign.setFrom(preferences.textAlign)
            val readiumPrefs = preferences.withoutReadiumTextAlign()
            editor?.apply {
                fontFamily.set(preferences.fontFamily)
                fontSize.set(preferences.fontSize)
                fontWeight.set(preferences.fontWeight)
                scroll.set(preferences.scroll)
                backgroundColor.set(preferences.backgroundColor)
                textColor.set(preferences.textColor)
                publisherStyles.set(preferences.publisherStyles)
                lineHeight.set(preferences.lineHeight)
                columnCount.set(preferences.columnCount)
                spread.set(preferences.spread)
                textAlign.set(null)

                mainScope.launch {
                    epubNavigator?.updatePreferences(readiumPrefs)
                    evaluateJavascript(MboParagraphAlign.applyScript())

                    val afterLocatorValue = epubNavigator?.currentLocator?.value
                    Log.d(TAG, "::updatePreferences - currentLocator AFTER=${afterLocatorValue?.let {
                        "href=${it.href}, prog=${it.locations.progression}"
                    } ?: "null"}")
                }
                state[epubPreferencesKey] = preferences
            }
        } catch (ex: Exception) {
            Log.e(TAG, "Error applying EpubPreferences: $ex")
        }
    }

    override fun setupNavigatorListeners() {
        val navigator = epubNavigator
        if (navigator == null) {
            Log.e(TAG, "::setupNavigatorListeners - epubNavigator is null this should never happen")
            return
        }

        val currentLocator = navigator.currentLocator
        navigator.removeDecorationListener(annotationDecorationListener)
        navigator.addDecorationListener(ANNOTATION_DECORATION_GROUP, annotationDecorationListener)
        if (currentLocator != null) {
            // Log the current value before subscribing
            val currentValue = currentLocator.value
            val subscribeTime = System.currentTimeMillis()
            Log.d(TAG, "::setupNavigatorListeners - BEFORE subscribe at t=${subscribeTime}, currentLocator.value = " +
                "href=${currentValue.href}, progression=${currentValue.locations.progression}")

            var emissionCount = 0
            currentLocator.throttleLatest(100.milliseconds)
                .distinctUntilChanged()
                .onEach { locator ->
                    emissionCount++
                    val emitTime = System.currentTimeMillis()
                    val elapsedMs = emitTime - subscribeTime
                    Log.d(TAG, "::setupNavigatorListeners - StateFlow emit #$emissionCount at t=$emitTime (elapsed=${elapsedMs}ms): " +
                        "href=${locator.href}, progression=${locator.locations.progression}")
                    onCurrentLocatorChanges(locator)
                    state[currentVisualCurrentLocatorKey] = locator
                }
                .launchIn(mainScope)
                .let { jobs.add(it) }

            subscribedFragmentInstance = navigator  // Track subscribed fragment
        } else {
            Log.d(TAG, "::setupNavigatorListeners - currentLocator is null - navigator not ready?")
        }
    }

    override fun storeState(): Bundle {
        return Bundle().apply {
            putString(
                currentVisualCurrentLocatorKey,
                (state[currentVisualCurrentLocatorKey] as? Locator)?.toJSON()?.toString()
            )

            val storedPrefs = this@EpubNavigator.state[epubPreferencesKey] as? EpubPreferences
            val prefs = storedPrefs ?: preferences
            prefs?.let {
                putString(
                    epubPreferencesKey,
                    Json.encodeToString(EpubPreferences.serializer(), it)
                )
            }
        }
    }

    private var pageLoadCount = 0

    override fun onPageLoaded() {
        pageLoadCount++
        val currentFragment = epubNavigator
        val currentLocatorValue = currentFragment?.currentLocator?.value
        Log.d(TAG, "::onPageLoaded #$pageLoadCount - " +
            "currentLocator=${currentLocatorValue?.let {
                "href=${it.href}, prog=${it.locations.progression}"
            } ?: "null"}, " +
            "pendingScroll=${pendingScrollToLocations != null}, " +
            "subscribedInstance=$subscribedFragmentInstance, " +
            "currentInstance=$currentFragment")

        visualListener.onPageLoaded()
        mainScope.launch {
            evaluateJavascript(MboParagraphAlign.applyScript())
        }

        pendingScrollToLocations?.let { locations ->
            Log.d(TAG, "::onPageLoaded #$pageLoadCount - executing pendingScrollToLocations: $locations")

            mainScope.launch {
                scrollToLocations(locations, toStart = false)
                // Fonts/CSS can reflow after the first paint (especially Burmese
                // webfonts). Re-anchor to cssSelector/domRange once layout settles.
                if (EpubRestore.hasElementAnchor(locations)) {
                    delay(EpubRestore.ELEMENT_REANCHOR_DELAY_MS)
                    Log.d(TAG, "::onPageLoaded - re-anchoring to element locator after layout")
                    scrollToLocations(locations, toStart = false)
                }
            }

            pendingScrollToLocations = null

        }

        // If fragment recreated (pause/resume), re-subscribe
        if (currentFragment != null && currentFragment !== subscribedFragmentInstance) {
            Log.d(TAG, "::onPageLoaded #$pageLoadCount - fragment changed detected! " +
                "current=$currentFragment, subscribed=$subscribedFragmentInstance, " +
                "currentLocator=${currentFragment.currentLocator?.value?.let {
                    "href=${it.href}, prog=${it.locations.progression}"
                }}")
            hasNotifiedIsReady = false
            jobs.forEach { it.cancel() }
            jobs.clear()
        }

        notifyIsReady()
    }

    private var hasNotifiedIsReady = false

    /**
     * Notify that the navigator is ready only once.
     */
    private fun notifyIsReady() {
        if (hasNotifiedIsReady) return

        hasNotifiedIsReady = true
        visualListener.onVisualReaderIsReady()
        setupNavigatorListeners()
    }

    override fun onPageChanged(
        pageIndex: Int,
        totalPages: Int,
        locator: Locator
    ) {
        visualListener.onPageChanged(pageIndex, totalPages, locator)
        state[currentVisualCurrentLocatorKey] = locator
    }

    override fun onExternalLinkActivated(url: AbsoluteUrl) {
        visualListener.onExternalLinkActivated(url)
    }

    override fun onCurrentLocatorChanges(locator: Locator) {
        visualListener.onVisualCurrentLocationChanged(locator)
    }

    override suspend fun release() {
        super.dispose()

        epubNavigator?.let { fragment ->
            withContext(Dispatchers.Main) {
                fragment.parentFragmentManager.commitNow { remove(fragment) }
            }
        }
        epubNavigator = null
        state.clear()
    }

    override fun dispose() {
        super.dispose()

        mainScope.launch {
            epubNavigator?.let { fragment ->
                fragment.parentFragmentManager.commitNow { remove(fragment) }
            }

            mainScope.coroutineContext.cancelChildren()
            epubNavigator = null
        }

        state.clear()
    }

    suspend fun evaluateJavascript(script: String): String? {
        val navigator = epubNavigator
        if (navigator == null) {
            Log.e(TAG, "::evaluateJavascript - epubNavigator is null!")
            return null
        }

        afterFragmentStarted()
        return withScope(mainScope) {
            navigator.evaluateJavascript(script)
        }
    }

    /** Selects the saved passage after navigating back to its resource. */
    suspend fun selectLocator(locator: Locator) {
        goToLocator(locator, animated = false)
        val locatorString = JSONObject.quote(locator.toJSON().toString())
        val script = """(function() {
          try {
            const locator = JSON.parse($locatorString);
            const locations = locator.locations || {};
            const domRange = locations.domRange;
            const boundary = (value) => {
              if (!value || !value.cssSelector) return null;
              const element = document.querySelector(value.cssSelector);
              if (!element) return null;
              if (value.charOffset !== undefined) {
                const textNodes = Array.from(element.childNodes)
                  .filter(node => node.nodeType === Node.TEXT_NODE);
                const node = textNodes[value.textNodeIndex];
                return node ? { node, offset: value.charOffset } : null;
              }
              return { node: element, offset: value.textNodeIndex };
            };
            let range = null;
            if (domRange && domRange.start && domRange.end) {
              const start = boundary(domRange.start);
              const end = boundary(domRange.end);
              if (start && end) {
                range = document.createRange();
                range.setStart(start.node, start.offset);
                range.setEnd(end.node, end.offset);
              }
            }
            const quote = locator.text && locator.text.highlight;
            // Older locators may contain element offsets encoded as text-node
            // indexes. Reject them when they no longer select the saved quote,
            // then recover from the quote below.
            if (range && quote && range.toString() !== quote) range = null;
            if (!range) {
              if (!quote) return false;
              const preferredRoot = locations.cssSelector
                ? document.querySelector(locations.cssSelector)
                : null;
              for (const root of [preferredRoot, document.body]) {
                if (!root) continue;
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                const nodes = [];
                let text = '';
                while (walker.nextNode()) {
                  const node = walker.currentNode;
                  nodes.push({ node, start: text.length, end: text.length + node.textContent.length });
                  text += node.textContent;
                }
                const startIndex = text.indexOf(quote);
                if (startIndex < 0) continue;
                const endIndex = startIndex + quote.length;
                const startNode = nodes.find(item => item.start <= startIndex && item.end > startIndex);
                const endNode = nodes.find(item => item.start < endIndex && item.end >= endIndex);
                if (!startNode || !endNode) continue;
                range = document.createRange();
                range.setStart(startNode.node, startIndex - startNode.start);
                range.setEnd(endNode.node, endIndex - endNode.start);
                break;
              }
              if (!range) return false;
            }
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
          } catch (_) { return false; }
        })()"""
        evaluateJavascript(script)
    }

    fun clearSelection() {
        epubNavigator?.clearSelection()
    }

    fun setNavigationConfig(config: FlutterNavigationConfig) {
        epubNavigator?.setNavigationConfig(config)
    }

    fun setScrollMode(isScrollMode: Boolean) {
        epubNavigator?.setScrollMode(isScrollMode)
    }

    fun goLeft(animated: Boolean) {
        val navigator = epubNavigator
        if (navigator == null) {
            Log.e(TAG, "::goLeft - epubNavigator is null!")
            return
        }

        Log.d(TAG, "::goLeft")
        navigator.goLeft(animated)
    }

    fun goRight(animated: Boolean) {
        val navigator = epubNavigator
        if (navigator == null) {
            Log.e(TAG, "::goRight - epubNavigator is null!")
            return
        }

        Log.d(TAG, "::goRight")
        navigator.goRight(animated)
    }

    private suspend fun afterFragmentStarted() {
        if (navigatorStarted.value) return

        navigatorStarted.first { it }
    }

    suspend fun isReaderReady(): Boolean {
        return withScope(mainScope) {
            epubNavigator?.isReaderReady() ?: false
        }
    }

    suspend fun getLocatorFragments(locator: Locator): Locator? {
        val json =
            evaluateJavascript("window.epubPage.getLocatorFragments(${locator.toJSON()}, $isVerticalScroll)")
        try {
            if (json == null || json == "null" || json == "undefined") {
                Log.e(
                    TAG,
                    "getLocatorFragments: window.epubPage.getVisibleRange failed!"
                )
                return null
            }
            val jsonLocator = jsonDecode(json) as JSONObject
            val locatorWithFragments = Locator.fromJSON(jsonLocator)

            return locatorWithFragments
        } catch (e: Exception) {
            Log.e(
                TAG,
                "getLocatorFragments: window.epubPage.getVisibleRange json: $json failed! $e"
            )
        }
        return null
    }

    /** Builds a locator for the selected DOM range without changing reader state. */
    suspend fun getCurrentSelection(): String? {
        // `window.readium` is ReadiumCSS' preference API; it does not expose the
        // current publication link. Take the resource identity from the native
        // navigator's current locator and add the DOM range returned by WebView.
        val current = epubNavigator?.currentLocator?.value ?: return null
        val script = """(function() {
          try {
            const selection = window.getSelection();
            if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
            const range = selection.getRangeAt(0).cloneRange();
            const highlight = range.toString();
            if (!highlight.trim()) return null;
            const selectorFor = (node) => {
              let element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
              if (!element) return null;
              const parts = [];
              while (element && element !== document.body) {
                const tag = element.tagName.toLowerCase();
                const sameTag = Array.from(element.parentElement?.children || [])
                  .filter(child => child.tagName === element.tagName);
                parts.unshift(tag + ':nth-of-type(' + (sameTag.indexOf(element) + 1) + ')');
                element = element.parentElement;
              }
              return 'body' + (parts.length ? ' > ' + parts.join(' > ') : '');
            };
            const boundary = (node, offset, isStart) => {
              const firstTextWithin = (candidate) => {
                if (!candidate) return null;
                if (candidate.nodeType === Node.TEXT_NODE) return candidate;
                for (const child of candidate.childNodes || []) {
                  const found = firstTextWithin(child);
                  if (found) return found;
                }
                return null;
              };
              const lastTextWithin = (candidate) => {
                if (!candidate) return null;
                if (candidate.nodeType === Node.TEXT_NODE) return candidate;
                const children = Array.from(candidate.childNodes || []);
                for (let index = children.length - 1; index >= 0; index--) {
                  const found = lastTextWithin(children[index]);
                  if (found) return found;
                }
                return null;
              };
              const nextTextAfter = (candidate) => {
                let current = candidate;
                while (current && current !== document.body) {
                  let sibling = current.nextSibling;
                  while (sibling) {
                    const found = firstTextWithin(sibling);
                    if (found) return found;
                    sibling = sibling.nextSibling;
                  }
                  current = current.parentNode;
                }
                return null;
              };
              const previousTextBefore = (candidate) => {
                let current = candidate;
                while (current && current !== document.body) {
                  let sibling = current.previousSibling;
                  while (sibling) {
                    const found = lastTextWithin(sibling);
                    if (found) return found;
                    sibling = sibling.previousSibling;
                  }
                  current = current.parentNode;
                }
                return null;
              };
              let textNode;
              let charOffset;
              if (node.nodeType === Node.TEXT_NODE) {
                textNode = node;
                charOffset = offset;
              } else {
                const children = Array.from(node.childNodes || []);
                if (isStart) {
                  for (let index = offset; index < children.length && !textNode; index++) {
                    textNode = firstTextWithin(children[index]);
                  }
                  if (!textNode) textNode = nextTextAfter(node);
                  charOffset = 0;
                } else {
                  for (let index = Math.min(offset, children.length) - 1;
                       index >= 0 && !textNode; index--) {
                    textNode = lastTextWithin(children[index]);
                  }
                  if (!textNode) textNode = previousTextBefore(node);
                  charOffset = textNode?.textContent?.length;
                }
              }
              const element = textNode?.parentElement;
              if (!element) return null;
              const textNodes = Array.from(element.childNodes)
                .filter(child => child.nodeType === Node.TEXT_NODE);
              const textNodeIndex = textNodes.indexOf(textNode);
              if (textNodeIndex < 0 || charOffset === undefined) return null;
              return {
                cssSelector: selectorFor(element),
                textNodeIndex: textNodeIndex,
                charOffset: charOffset
              };
            };
            const start = boundary(range.startContainer, range.startOffset, true);
            const end = boundary(range.endContainer, range.endOffset, false);
            if (!start || !end) return null;
            const ancestor = range.commonAncestorContainer;
            const root = ancestor.nodeType === Node.TEXT_NODE ? ancestor.parentElement : ancestor;
            const cssSelector = selectorFor(root);
            if (!cssSelector) return null;
            const before = document.createRange();
            before.selectNodeContents(root);
            before.setEnd(range.startContainer, range.startOffset);
            const after = document.createRange();
            after.selectNodeContents(root);
            after.setStart(range.endContainer, range.endOffset);
            return {
              locations: { cssSelector, domRange: { start, end } },
              text: {
                highlight,
                before: Array.from(before.toString()).slice(-64).join(''),
                after: Array.from(after.toString()).slice(0, 64).join('')
              }
            };
          } catch (_) { return null; }
        })()"""
        val result = evaluateJavascript(script) ?: return null
        if (result == "null" || result == "undefined") return null
        return try {
            val selection = jsonDecode(result) as? JSONObject ?: return null
            val locator = current.toJSON().apply {
                put("locations", JSONObject(current.locations.toJSON().toString()).apply {
                    put("cssSelector", selection.getJSONObject("locations").optString("cssSelector"))
                    put("domRange", selection.getJSONObject("locations").getJSONObject("domRange"))
                })
                put("text", selection.getJSONObject("text"))
            }
            locator.toString()
        } catch (ex: Exception) {
            Log.w(TAG, "Could not build locator for current EPUB selection", ex)
            null
        }
    }

    suspend fun firstVisibleElementLocator(): Locator? {
        val navigator = epubNavigator
        if (navigator == null) {
            Log.e(TAG, "::firstVisibleElementLocator - epubNavigator is null!")
            return null
        }

        return withScope(mainScope) {
            navigator.firstVisibleElementLocator()
        }
    }

    suspend fun applyDecorations(
        decorations: List<Decoration>,
        group: String
    ) {
        mainScope.async {
            epubNavigator?.applyDecorations(decorations, group)
        }.await()
    }

    private suspend fun scrollToLocations(
        locations: Locator.Locations,
        toStart: Boolean
    ) {
        val json = locations.toJSON().toString()
        val beforeScroll = epubNavigator?.currentLocator?.value
        Log.d(TAG, "::scrollToLocations: BEFORE scroll - currentLocator=${beforeScroll?.let {
            "href=${it.href}, prog=${it.locations.progression}"
        } ?: "null"}")
        Log.d(TAG, "::scrollToLocations: Go to locations $json, toStart: $toStart")

        evaluateJavascript("window.epubPage.scrollToLocations($json,$isVerticalScroll,$toStart);")

        val afterScroll = epubNavigator?.currentLocator?.value
        Log.d(TAG, "::scrollToLocations: AFTER scroll - currentLocator=${afterScroll?.let {
            "href=${it.href}, prog=${it.locations.progression}"
        } ?: "null"}")
    }

    /**
     * Go to a specific locator in the EPUB navigator, this scrolls to the locator position if needed.
     */
    suspend fun goToLocator(locator: Locator, animated: Boolean) {
        mainScope.async {
            val locations = locator.locations
            val shouldScroll = canScroll(locations)
            val locatorHref = locator.href
            val currentHref = currentLocator?.value?.href
            val shouldGo = currentHref?.isEquivalent(locatorHref) == false

            // TODO: Figure out why we can't just use rely on Readium's own go-function to scroll
            // the locator.
            if (shouldGo) {
                Log.d(TAG, "::goToLocator: Go to $locatorHref from $currentHref")
                pendingScrollToLocations = locations
                go(locator, animated)
            } else if (!shouldScroll) {
                Log.d(TAG, "::goToLocator: Already at $locatorHref, no scroll data, staying put")
            } else {
                val currentProgression = currentLocator?.value?.locations?.progression
                val targetProgression = locations.progression
                val hasElementAnchor = EpubRestore.hasElementAnchor(locations)

                if (EpubRestore.shouldSkipProgressionScroll(
                        currentProgression,
                        targetProgression,
                        hasElementAnchor,
                    )
                ) {
                    Log.d(TAG, "::goToLocator: Already at $locatorHref with correct progression " +
                        "(current=$currentProgression, target=$targetProgression), " +
                        "skipping progression-only scroll to avoid drift")
                    return@async
                }

                Log.d(TAG, "::goToLocator: Already at $locatorHref, scroll to position " +
                    "(current=$currentProgression, target=$targetProgression, " +
                    "elementAnchor=$hasElementAnchor)")

                scrollToLocations(locations, false)
                if (hasElementAnchor) {
                    delay(EpubRestore.ELEMENT_REANCHOR_DELAY_MS)
                    scrollToLocations(locations, false)
                }
            }
        }.await()
    }

    /**
     * Clears any deferred scroll that was queued before an explicit external restore/navigation call.
     */
    fun clearPendingScrollTarget() {
        if (pendingScrollToLocations != null) {
            Log.d(TAG, "::clearPendingScrollTarget")
        }
        pendingScrollToLocations = null
    }

    companion object {
        const val ANNOTATION_DECORATION_GROUP = "book-annotations"

        fun restoreState(
            publication: Publication,
            listener: VisualListener,
            state: Bundle
        ): EpubNavigator {
            val locator = state.getString(currentVisualCurrentLocatorKey)
                ?.let { json -> Locator.fromJSON(JSONObject(json)) }
            val preferences = state.getString(epubPreferencesKey)
                ?.let { string -> Json.decodeFromString<EpubPreferences>(string) }
                ?: EpubPreferences()

            Log.d(TAG, "::restoreState - locator: $locator, preferences: $preferences")

            return EpubNavigator(publication, locator, listener, preferences)
        }
    }
}
