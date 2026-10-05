package com.seph.capyflow

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.io.IOException

class ConnectionAndMessagesTest {
    @Test fun temporaryFailureRetriesOnceAndSucceeds() = runBlocking {
        var calls=0;var pauses=0
        assertEquals("ready",discoverWithRetry({pauses++}){if(++calls==1)throw IOException("cold");"ready"})
        assertEquals(2,calls);assertEquals(1,pauses)
    }
    @Test fun persistentFailureStopsAfterTwoAttempts() = runBlocking {
        var calls=0
        try { discoverWithRetry({}){calls++;throw IOException("offline")};fail() }
        catch(_:IOException){assertEquals(2,calls)}
    }
    @Test fun permanentHttpFailureDoesNotRetry() = runBlocking {
        var calls=0
        try { discoverWithRetry({fail("Unexpected retry")}){calls++;throw HttpResponseException(403)};fail() }
        catch(_:HttpResponseException){assertEquals(1,calls)}
    }
    @Test fun cancellationDoesNotRetry() = runBlocking {
        var calls=0
        try { discoverWithRetry({fail("Unexpected retry")}){calls++;throw CancellationException()};fail() }
        catch(_:CancellationException){assertEquals(1,calls)}
    }
    @Test fun manualChoiceDuringRetryCannotBeOverwritten() = runBlocking {
        var epoch=1;var automatic=true;var address="old";var calls=0
        refreshDiscoveredServer(1,{epoch},{automatic},{
            discoverWithRetry({automatic=false;epoch++;address="manual"}) {
                if(++calls==1)throw IOException("cold")
                "late"
            }
        }){address=it}
        assertEquals("manual",address)
    }
    @Test fun technicalErrorsAreReplacedButValidationIsPreserved() {
        assertEquals("Try again",UserMessages.failure(IllegalStateException("Firebase MSI token HTTP 403"),"Try again"))
        assertEquals("That username is already taken.",UserMessages.failure(RuntimeException(IllegalStateException("That username is already taken."))))
        assertEquals("Check your connection and try again.",UserMessages.failure(RuntimeException(java.net.UnknownHostException("internal-host"))))
    }
    @Test fun onlyPublishedStableAndroidReleasesAreOffered() {
        fun release(draft:Boolean=false,preview:Boolean=false,tag:String="android-dev12")=JSONObject().put("draft",draft).put("prerelease",preview).put("tag_name",tag)
        assertTrue(UpdatePolicy.acceptsRelease(release()))
        assertFalse(UpdatePolicy.acceptsRelease(release(draft=true)))
        assertFalse(UpdatePolicy.acceptsRelease(release(preview=true)))
        assertFalse(UpdatePolicy.acceptsRelease(release(tag="ios-v12")))
    }
}
