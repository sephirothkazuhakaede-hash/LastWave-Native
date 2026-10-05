package com.seph.capyflow

import org.junit.Assert.assertEquals
import org.junit.Test
import org.json.JSONObject
import java.util.Base64

class DiscoveryDocumentTest {
    @Test fun explicitRefreshDecodesLatestBranchResponse(){
        val body="""{"url":"https://new.trycloudflare.com"}"""
        val wrapped=JSONObject().put("encoding","base64").put("content",Base64.getEncoder().encodeToString(body.toByteArray()).chunked(12).joinToString("\n"))
        assertEquals("https://new.trycloudflare.com",discoveryDocument(wrapped.toString(),true).getString("url"))
        assertEquals("https://new.trycloudflare.com",discoveryDocument(body,false).getString("url"))
    }
}
