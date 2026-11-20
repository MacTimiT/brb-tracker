package dev.mactimit.brb_tracker

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class StreamCatalogTest {
    @Test fun pageKeepsChannelOrderAndAdvancesPastFilteredSlots() {
        val entries = JSONArray()
        repeat(21) { index ->
            entries.put(JSONObject().put("id", "stream%05d".format(index)).put("title", "Stream $index")
                .put("live_status", if (index == 0) "is_live" else "was_live"))
        }
        val page = StreamCatalog.page(JSONObject().put("entries", entries), 1)
        val streams = page.getJSONArray("streams")
        assertEquals(19, streams.length())
        assertEquals("Stream 1", streams.getJSONObject(0).getString("title"))
        assertEquals("Stream 19", streams.getJSONObject(18).getString("title"))
        assertEquals(21, page.getInt("next"))
        val last = StreamCatalog.page(JSONObject().put("entries", JSONArray().put(entries.getJSONObject(20))), 21)
        assertTrue(last.isNull("next"))
        assertEquals("Stream 20", last.getJSONArray("streams").getJSONObject(0).getString("title"))
    }
}
