package com.seph.capyflow

import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException

class AccountCompatibilityTest {
    @Test fun creatorUidSurvivesCloudPayloadAndUsernameChanges(){
        val original=JSONObject("""{"id":"source","name":"Mix","tracks":[],"ownerID":"stable-uid","creatorUsername":"old"}""")
        val restored=Playlist.from(original).copy(name="Updated")
        assertEquals("stable-uid",Playlist.from(restored.json()).ownerID)
        assertEquals("old",restored.json().getString("creatorUsername"))
    }
    @Test fun usernamesMatchSharedReservationPolicy(){
        listOf("seph","meow","a_b","listener_1234567890").forEach{assertTrue(it,UsernamePolicy.valid(it))}
        listOf("ab","@seph","Google","google","a..b","a-b","a.",".ab","abcdefghijklmnopqrstu").forEach{assertFalse(it,UsernamePolicy.valid(it))}
    }
    @Test fun transientDownloadRetriesThenSucceeds()=runBlocking{
        var attempts=0;val waits=mutableListOf<Long>()
        retryAudioDownload(wait={waits+=it}){attempt -> assertEquals(attempt,attempts++);if(attempt<2)throw DownloadHttpException(502)}
        assertEquals(3,attempts);assertEquals(listOf(1000L,2000L),waits)
    }
    @Test fun cancellationDoesNotRetry()=runBlocking{
        var attempts=0
        try{retryAudioDownload(wait={fail("Cancellation must not wait")}){attempts++;throw CancellationException()};fail("Expected cancellation")}catch(_:CancellationException){}
        assertEquals(1,attempts)
    }
    @Test fun permanentHttpFailureDoesNotRetry()=runBlocking{
        var attempts=0
        try{retryAudioDownload(wait={fail("Permanent error must not wait")}){attempts++;throw DownloadHttpException(401)};fail("Expected HTTP failure")}catch(e:DownloadHttpException){assertEquals(401,e.status)}
        assertEquals(1,attempts)
    }
}
