package dev.mulev.flureadium

import kotlin.test.Test
import kotlin.test.assertEquals
import org.json.JSONObject

internal class DecorationTextScopeTest {
    private fun locator(start: String, end: String, scope: String = start): JSONObject =
        JSONObject().apply {
            put("href", "chapter.xhtml")
            put("type", "application/xhtml+xml")
            put("text", JSONObject().put("highlight", "First paragraph. Second paragraph."))
            put("locations", JSONObject().apply {
                put("cssSelector", scope)
                put("progression", 0.25)
                put("domRange", JSONObject().apply {
                    put("start", JSONObject().put("cssSelector", start)
                        .put("textNodeIndex", 0).put("charOffset", 0))
                    put("end", JSONObject().put("cssSelector", end)
                        .put("textNodeIndex", 0).put("charOffset", 12))
                })
            })
        }

    @Test
    fun savedMultiParagraphAnnotationSearchesBothParagraphs() {
        val json = locator("body > p:nth-of-type(1)", "body > p:nth-of-type(3) > span:nth-of-type(1)")
        val range = json.getJSONObject("locations").getJSONObject("domRange").toString()
        val fixed = decorationTextScope(json)
        assertEquals("body", fixed.getJSONObject("locations").getString("cssSelector"))
        assertEquals(range, fixed.getJSONObject("locations").getJSONObject("domRange").toString())
        assertEquals(0.25, fixed.getJSONObject("locations").getDouble("progression"))
        assertEquals("First paragraph. Second paragraph.", fixed.getJSONObject("text").getString("highlight"))
    }

    @Test
    fun inlineSiblingsSearchTheirSharedParagraph() {
        val paragraph = "body > div:nth-of-type(1) > p:nth-of-type(2)"
        val fixed = decorationTextScope(locator("$paragraph > span:nth-of-type(1)", "$paragraph > em:nth-of-type(1)"))
        assertEquals(paragraph, fixed.getJSONObject("locations").getString("cssSelector"))
    }

    @Test
    fun singleElementAndAlreadyBroadScopesRemainSpecific() {
        val first = "body > p:nth-of-type(1)"
        assertEquals(first, decorationTextScope(locator(first, first)).getJSONObject("locations").getString("cssSelector"))
        val fixed = decorationTextScope(locator(first, "body > p:nth-of-type(2)", "#chapter"))
        assertEquals("#chapter", fixed.getJSONObject("locations").getString("cssSelector"))
    }

    @Test
    fun nonPathEndpointSelectorsUseTheDocumentScope() {
        val fixed = decorationTextScope(locator("#paragraph-one", "#paragraph-two"))
        assertEquals("body", fixed.getJSONObject("locations").getString("cssSelector"))
    }

    @Test
    fun locatorsWithoutRangeAreUnchanged() {
        val json = locator("#paragraph-one", "#paragraph-two")
        json.getJSONObject("locations").remove("domRange")
        val original = json.toString()
        assertEquals(original, decorationTextScope(json).toString())
    }
}
