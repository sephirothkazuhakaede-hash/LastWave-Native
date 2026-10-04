package com.seph.capyflow
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
class PlaybackStartupTest {
    @Test fun fastPrimaryDoesNotStartFallback()=runBlocking{var fallback=false;assertEquals("backend",firstWorkingSource(100,{"backend"},{fallback=true;"direct"}));assertFalse(fallback)}
    @Test fun slowPrimaryYieldsToFallbackAndIsCancelled()=runBlocking{var cancelled=false;val winner=firstWorkingSource(20,{try{delay(2000);"backend"}finally{cancelled=true}},{"direct"});assertEquals("direct",winner);assertTrue(cancelled)}
    @Test fun failedPrimaryStartsFallbackImmediately()=runBlocking{val value=withTimeout(500){firstWorkingSource(2000,{error("offline")},{"direct"})};assertEquals("direct",value)}
    @Test fun failedFallbackDoesNotDiscardWorkingPrimary()=runBlocking{assertEquals("backend",firstWorkingSource(5,{delay(30);"backend"},{error("unavailable")}))}
    @Test fun parentCancellationStopsBothResolvers()=runBlocking{var cancelled=0;val job=launch{firstWorkingSource(5,{try{delay(2000);"backend"}finally{cancelled++}},{try{delay(2000);"direct"}finally{cancelled++}})};delay(30);job.cancelAndJoin();assertEquals(2,cancelled)}
}
