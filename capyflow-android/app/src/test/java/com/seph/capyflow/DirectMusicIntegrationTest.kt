package com.seph.capyflow

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Explicit smoke check; regular unit tests do not require Internet access. */
class DirectMusicIntegrationTest {
    @Test fun resolvesAndReadsAudioWithoutMSI() = runBlocking {
        assumeTrue(System.getenv("CAPY_DIRECT_SMOKE")=="1")
        val id=System.getenv("CAPY_DIRECT_VIDEO") ?: "4De_ERjvuUI"
        val high=DirectMusic.resolve(id,"automatic")
        val low=DirectMusic.resolve(id,"dataSaver")
        println("Direct source formats: best=${high.audio.container}/${high.audio.bitrateKbps}kbps, saver=${low.audio.container}/${low.audio.bitrateKbps}kbps")
        assertTrue(high.audio.url.startsWith("https://"));assertTrue(low.audio.url.startsWith("https://"))
        if(high.audio.bitrateKbps!=null && low.audio.bitrateKbps!=null)assertTrue(high.audio.bitrateKbps>=low.audio.bitrateKbps)
        val client=OkHttpClient.Builder().callTimeout(20,TimeUnit.SECONDS).build()
        client.newCall(Request.Builder().url(high.audio.url).header("User-Agent",DirectMusic.USER_AGENT).header("Range","bytes=0-65535").build()).execute().use{r ->
            assertTrue("Audio HTTP ${r.code}",r.isSuccessful)
            assertFalse(r.header("Content-Type").orEmpty().contains("json"))
            val buffer=ByteArray(256);assertTrue(r.body!!.byteStream().read(buffer)>0)
        }
    }
}
