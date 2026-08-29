@file:OptIn(ExperimentalReadiumApi::class, ExperimentalReadiumApi::class)

package dev.mulev.flureadium

import android.util.Log
import androidx.core.graphics.toColorInt
import dev.mulev.flureadium.models.FlutterMediaOverlay
import org.json.JSONObject
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.preferences.Spread
import org.readium.r2.navigator.preferences.TextAlign
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.InternalReadiumApi
import org.readium.r2.shared.publication.Href
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Manifest
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.flatten
import org.readium.r2.shared.publication.html.cssSelector
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.mediatype.MediaType
import org.readium.r2.shared.util.resource.Resource
import org.readium.r2.shared.util.resource.TransformingResource
import org.readium.r2.shared.util.resource.filename
import org.readium.r2.navigator.preferences.Color as ReadiumColor

private const val TAG = "ReadiumExtensions"

private fun readiumColorFromCSS(cssColor: String): ReadiumColor {
    val color = cssColor.toColorInt()
    return ReadiumColor(color)
}

fun decorationFromMap(decoMap: Map<String, Any>): Decoration? {
    try {
        val id = decoMap["decorationId"] as String
        val locator = Locator.fromJSON(jsonDecode(decoMap["locator"] as String) as JSONObject)
            ?: throw Exception("Failed to deserialize locator")

        @Suppress("UNCHECKED_CAST")
        val style = decorationStyleFromMap(decoMap["style"] as Map<String, String>)
            ?: throw Exception("Failed to deserialize decoration")
        return Decoration(id, locator, style)
    } catch (ex: Exception) {
        Log.e("ReadiumExtensions", "Error mapping JSONObject to Decoration.Style: $ex")
        return null
    }
}

fun decorationStyleFromMap(decoMap: Map<*, *>?): Decoration.Style? {
    try {
        if (decoMap == null) return null

        val styleStr = decoMap["style"] as String
        val tintColorStr = decoMap["tint"] as String
        val style = when (styleStr) {
            "underline" -> Decoration.Style.Underline(readiumColorFromCSS(tintColorStr).int)
            "highlight" -> Decoration.Style.Highlight(readiumColorFromCSS(tintColorStr).int)
            else -> Decoration.Style.Highlight(readiumColorFromCSS(tintColorStr).int)
        }
        return style
    } catch (ex: Exception) {
        Log.e("ReadiumExtensions", "Error mapping JSONObject to Decoration.Style: $ex")
        return null
    }
}

fun epubPreferencesFromMap(
    prefMap: Map<String, String>,
    defaults: EpubPreferences?,
): EpubPreferences {
    try {
        val newPreferences = EpubPreferences(
            fontFamily = prefMap["fontFamily"]?.let { FontFamily(it) } ?: defaults?.fontFamily,
            fontSize = prefMap["fontSize"]?.toDoubleOrNull() ?: defaults?.fontSize,
            fontWeight = prefMap["fontWeight"]?.toDoubleOrNull() ?: defaults?.fontWeight,
            scroll = prefMap["verticalScroll"]?.toBoolean() ?: defaults?.scroll,
            backgroundColor = prefMap["backgroundColor"]?.let { readiumColorFromCSS(it) }
                ?: defaults?.backgroundColor,
            textColor = prefMap["textColor"]?.let { readiumColorFromCSS(it) }
                ?: defaults?.textColor,
            pageMargins = prefMap["pageMargins"]?.toDoubleOrNull() ?: defaults?.pageMargins,
            lineHeight = prefMap["lineHeight"]?.toDoubleOrNull() ?: defaults?.lineHeight,
            publisherStyles = prefMap["publisherStyles"]?.toBoolean() ?: defaults?.publisherStyles,
            // Default to single-column / no-spread when unset so tablets do not
            // automatically switch to dual-page layout.
            columnCount = prefMap["columnCount"]?.let { columnCountFromWire(it) }
                ?: defaults?.columnCount
                ?: ColumnCount.ONE,
            spread = prefMap["spread"]?.let { spreadFromWire(it) }
                ?: defaults?.spread
                ?: Spread.NEVER,
            textAlign = prefMap["textAlign"]?.let { textAlignFromWire(it) }
                ?: defaults?.textAlign,
        )
        return newPreferences
    } catch (ex: Exception) {
        Log.e("ReadiumExtensions", "Error mapping JSONObject to EpubPreferences: $ex")
        return EpubPreferences(columnCount = ColumnCount.ONE, spread = Spread.NEVER)
    }
}

private fun columnCountFromWire(value: String): ColumnCount? = when (value) {
    "auto" -> ColumnCount.AUTO
    "1" -> ColumnCount.ONE
    "2" -> ColumnCount.TWO
    else -> null
}

private fun spreadFromWire(value: String): Spread? = when (value) {
    "auto" -> Spread.AUTO
    "never" -> Spread.NEVER
    "always" -> Spread.ALWAYS
    else -> null
}

private fun textAlignFromWire(value: String): TextAlign? = when (value) {
    "center" -> TextAlign.CENTER
    "justify" -> TextAlign.JUSTIFY
    "start" -> TextAlign.START
    "end" -> TextAlign.END
    "left" -> TextAlign.LEFT
    "right" -> TextAlign.RIGHT
    else -> null
}

/**
 * ReadiumCSS applies `p { text-align: inherit !important }` whenever
 * `--USER__textAlign` is set, which overwrites publisher center/right.
 * We keep the Flutter `textAlign` value for our own CSS variable instead.
 */
internal object MboParagraphAlign {
    @Volatile
    var cssValue: String = "default"

    fun from(align: TextAlign?): String = when (align) {
        TextAlign.JUSTIFY -> "justify"
        TextAlign.LEFT -> "left"
        else -> "default"
    }

    fun setFrom(align: TextAlign?) {
        cssValue = from(align)
    }

    fun applyScript(align: String = cssValue): String {
        val safe = align.filter { it.isLetter() }.ifEmpty { "default" }
        return """
            (function(){
              try { localStorage.setItem('mboParaAlign', '$safe'); } catch(e) {}
              window.__MBO_PARA_ALIGN = '$safe';
              function applyDoc(doc) {
                if (!doc || !doc.documentElement) return;
                var override = ('$safe' === 'left' || '$safe' === 'justify');
                try {
                  if (override) {
                    doc.documentElement.style.setProperty('--MBO__paraAlign', '$safe');
                    doc.documentElement.setAttribute('data-mbo-para-align', '$safe');
                  } else {
                    doc.documentElement.style.removeProperty('--MBO__paraAlign');
                    doc.documentElement.removeAttribute('data-mbo-para-align');
                  }
                } catch (e) {}
                try {
                  var r = doc.defaultView && doc.defaultView.readium;
                  if (r && r.setCSSProperties) {
                    r.setCSSProperties({'--MBO__paraAlign': override ? '$safe' : null});
                  }
                } catch (e) {}
                try {
                  var frames = doc.querySelectorAll('iframe');
                  for (var i = 0; i < frames.length; i++) {
                    try { applyDoc(frames[i].contentDocument); } catch (err) {}
                  }
                } catch (e) {}
              }
              if (window.__mboSetParaAlign) window.__mboSetParaAlign('$safe');
              else applyDoc(document);
            })();
        """.trimIndent()
    }
}

internal fun EpubPreferences.withoutReadiumTextAlign(): EpubPreferences = copy(textAlign = null)

private const val READIUM_FLUTTER_PATH_PREFIX =
    "https://readium/assets/flutter_assets/packages/flureadium"

// Helper for injecting extra files into an epub
fun Resource.injectScriptsAndStyles(): Resource =
    TransformingResource(this) { bytes ->
        val props = this.properties().getOrNull()
        val filename = props?.filename

        // Skip all non-html files
        if (filename?.endsWith("html", ignoreCase = true) != true) {
            return@TransformingResource Try.success(bytes)
        }

        val content = bytes.toString(Charsets.UTF_8).trim()
        val headEndIndex = content.indexOf("</head>", 0, true)
        if (headEndIndex == -1) {
            Log.w(TAG, "No </head> element found, cannot inject scripts in: $filename")
            return@TransformingResource Try.success(bytes)
        }

        if (content.take(headEndIndex).contains(READIUM_FLUTTER_PATH_PREFIX)) {
            Log.d(TAG, "Skip injecting - already done for: $filename")
            return@TransformingResource Try.success(bytes)
        }

        Log.d(TAG, "Injecting files into: $filename")

        val injectLines = listOf(
            """<script type="text/javascript" src="$READIUM_FLUTTER_PATH_PREFIX/assets/helpers/comics.js"></script>""",
            """<script type="text/javascript" src="$READIUM_FLUTTER_PATH_PREFIX/assets/helpers/epub.js"></script>""",
            """<script type="text/javascript">window.__MBO_PARA_ALIGN="${MboParagraphAlign.cssValue}";</script>""",
            """<script type="text/javascript" src="$READIUM_FLUTTER_PATH_PREFIX/assets/helpers/preserve-text-align.js"></script>""",
            """<script type="text/javascript">const isAndroid = true; const isIos = false;</script>""",
            """<link rel="stylesheet" type="text/css" href="$READIUM_FLUTTER_PATH_PREFIX/assets/helpers/comics.css"></link>""",
            """<link rel="stylesheet" type="text/css" href="$READIUM_FLUTTER_PATH_PREFIX/assets/helpers/epub.css"></link>""",
        )
        val newContent = StringBuilder(content)
            .insert(headEndIndex, "\n" + injectLines.joinToString("\n") + "\n")
            .toString()

        Try.success(newContent.toByteArray())
    }

val syncNarrationsMediaType = MediaType("application/vnd.syncnarr+json")

/**
 * Check if the publication has any media overlays.
 */
fun Publication.hasMediaOverlays() = this.readingOrder.any { r ->
    r.alternates.any { a ->
        a.mediaType == syncNarrationsMediaType
    } || r.properties["media-overlay"] != null
}

/**
 * Get the media overlays for the publication, if any.
 * Note: If an item in the reading order does not have a media overlay, it will be represented by null
 */
suspend fun Publication.getMediaOverlays(): List<FlutterMediaOverlay?>? {
    if (!hasMediaOverlays()) return null

    // Flatten TOC for title lookup
    val toc = tableOfContents.flatten().map { Pair(it.href.toString(), it.title) }

    // Remember last matched TOC item for titles
    var lastTocMatch: Pair<String, String?>? = null

    return this.readingOrder.mapNotNull { r ->
        r.alternates.find { a ->
            a.mediaType == MediaType("application/vnd.syncnarr+json")
        }?.copy(title = r.title)
    }.mapIndexedNotNull { index, link ->
        val jsonString =
            this.get(link)?.read()?.getOrNull()?.let { String(it) } ?: return@mapIndexedNotNull null
        val jsonObject = JSONObject(jsonString)
        FlutterMediaOverlay.fromJson(jsonObject, index + 1, link.title ?: "")
    }
        .map { mo ->
            val items = mo.items.map { item ->
                // Find best matching title from TOC
                val match = toc.find { tocItem ->
                    tocItem.first == item.text
                }

                if (match?.second != null) {
                    lastTocMatch = match
                    item.copy(title = match.second ?: "")
                } else if (lastTocMatch?.second != null && lastTocMatch.first.substringBefore("#") == item.textFile) {
                    item.copy(title = lastTocMatch.second ?: "")
                } else {
                    item
                }
            }

            return@map FlutterMediaOverlay(items)
        }
}

/**
 * Create a new Publication containing only the audio files from the media overlays.
 * This is used for the Sync Audiobook navigator.
 * Returns the new Publication and the list of media overlays, if any.
 * If there are no media overlays, returns the original publication and null.
 */
@OptIn(InternalReadiumApi::class)
suspend fun Publication.makeSyncAudiobook(): Pair<Publication, List<FlutterMediaOverlay?>?> {
    if (!hasMediaOverlays()) {
        return Pair(this, null)
    }

    val mediaOverlays = getMediaOverlays() ?: return Pair(this, null)

    val manifest = Manifest(
        context = context,
        metadata = metadata.copy(conformsTo = setOf(Publication.Profile.AUDIOBOOK)),
        resources = resources,
        links = links,
        readingOrder = mediaOverlays.mapNotNull { overlay ->
            val item = overlay?.items?.first() ?: return@mapNotNull null

            Href.invoke(item.audioFile)
                ?.let { href ->
                    Link(
                        href,
                        mediaType = item.audioMediaType,
                        duration = overlay.duration,
                        title = item.title
                    )
                }
        }
    )

    val pseudoPublication = Publication.Builder(manifest, container).build()
    return Pair(pseudoPublication, mediaOverlays)
}

/**
 * Get the time offset from a Locator's fragments, if any.
 */
fun Locator.getTimeOffset(): Double? {
    val timeFragment = locations.fragments.find { it.startsWith("t=") } ?: return null
    return timeFragment.substringAfter("t=").toDoubleOrNull()
}

/**
 * Get the text id from a Locator's fragments or css selector, if any.
 */
fun Locator.getTextId(): String? {
    val cssFragment =
        locations.fragments.find { it.startsWith("#") } ?: locations.cssSelector ?: return null
    return cssFragment.removePrefix("#")
}

/**
 * Make a new copy with a new time fragment
 */
fun Locator.copyWithTimeFragment(time: Double): Locator {
    return copy(
        locations = locations.copy(
            fragments = listOf("${time}")
        )
    )
}
