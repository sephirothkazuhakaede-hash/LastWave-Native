package com.seph.capyflow

import org.junit.Assert.*
import org.junit.Test
import kotlinx.coroutines.launch
import org.json.JSONObject

class CompatibilityTest {
    @Test fun durationHandlesHourLongTracksAndRejectsInvalidValues() {
        assertEquals(3723.0,Catalog.duration("1:02:03")!!,0.0)
        assertEquals(242.0,Catalog.duration("4:02")!!,0.0)
        assertNull(Catalog.duration("1:99"));assertNull(Catalog.duration("Live"))
    }
    @Test fun lyricsPreserveMultipleTimestampsAndSortForSeeking() {
        val lines=Catalog.parseLyrics("[00:20.50]Second\n[00:03.00][00:10.00]Repeated")
        assertEquals(listOf(3.0,10.0,20.5),lines.map{it.time})
        assertEquals("Repeated",lines.first().text)
    }
    @Test fun conversationIDMatchesIOSRegardlessOfParticipantOrder() {
        assertEquals("a_z",SocialModel.conversationID("z","a"))
        assertEquals(SocialModel.conversationID("a","z"),SocialModel.conversationID("z","a"))
    }
    @Test fun playlistPayloadReadsIOSAndPreservesRecordingIdentity() {
        val ios=JSONObject("""{"id":"playlist-1","name":"Our songs","tracks":[{"id":"album-track","title":"Song","artist":"Artist","duration":210.5,"mediaID":"audio-video","artworkURL":"https://example.com/art.jpg","albumTitle":"Album","albumID":"browse-album","trackNumber":4}]}""")
        val p=Playlist.from(ios)
        assertEquals("audio-video",p.tracks.first().playableID)
        val restored = Playlist.from(p.json())
        assertEquals(p.id,restored.id);assertEquals(p.tracks.first().playableID,restored.tracks.first().playableID)
        assertEquals("browse-album",restored.tracks.first().json().getString("albumID"))
        assertEquals(4,restored.tracks.first().json().getInt("trackNumber"))
    }
    @Test fun songSearchDoesNotTreatMusicVideosAsAudioRecordings() {
        fun row(id:String,type:String)=JSONObject("""{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"$id"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"},{"text":"3:42"}]}}}],"navigationEndpoint":{"watchEndpoint":{"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"$type"}}}}}}""")
        val root=JSONObject().put("audio",row("audio","MUSIC_VIDEO_TYPE_ATV")).put("video",row("video","MUSIC_VIDEO_TYPE_OMV"))
        val songs=Catalog.parseSongs(root)
        assertEquals(listOf("audio"),songs.map{it.id});assertEquals(222.0,songs.first().duration!!,0.0)
    }

    @Test fun lyricsRejectOtherVersionsAndSkipEmptyCandidates() {
        val records=org.json.JSONArray("""[{"trackName":"Song (Live)","artistName":"Artist","duration":200,"syncedLyrics":"[00:01]Wrong version"},{"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"","plainLyrics":null},{"trackName":"Song","artistName":"Artist","duration":202,"plainLyrics":"Correct line"}]""")
        assertEquals(listOf(Lyric(null,"Correct line")),Catalog.selectLyrics(records,Track("id","Song (Official Audio)","Artist",200.0)))
    }
    @Test fun offlineLyricsRoundTripUnicodeAndUntimedLines() {
        val lines=listOf(Lyric(1.25,"こんにちは"),Lyric(null,"Plain lyric"))
        assertEquals(lines,Catalog.decodeLyrics(Catalog.encodeLyrics(lines)))
    }
    @Test fun artworkEnlargementPreservesSignedAndUnrelatedURLs() {
        assertEquals("https://lh3.googleusercontent.com/art=w1200-h1200-l90",Catalog.artworkForDisplay("https://lh3.googleusercontent.com/art=w60-h60-l90"))
        val signed="https://lh3.googleusercontent.com/art=w60-h60?signature=abc"
        assertEquals(signed,Catalog.artworkForDisplay(signed))
        assertEquals("https://example.com/art=s60",Catalog.artworkForDisplay("https://example.com/art=s60"))
    }
    @Test fun albumRowsPreserveTrackOrderArtistFallbackAndRecordingIdentity() {
        fun row(id:String,title:String,artist:String,index:Int)=JSONObject("""{"musicResponsiveListItemRenderer":{"index":{"runs":[{"text":"$index"}]},"playlistItemData":{"videoId":"$id"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"$title"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"$artist"}]}}}],"fixedColumns":[{"musicResponsiveListItemFixedColumnRenderer":{"text":{"runs":[{"text":"3:20"}]}}}]}}""")
        val album=Album("MPRE1","Album","Album Artist","https://example.com/art")
        val root=JSONObject().put("rows",org.json.JSONArray(listOf(row("one","First","",1),row("two","Second","Guest",2),row("one","First","",1))))
        val tracks=Catalog.parseAlbumTracks(root,album)
        assertEquals(listOf("one","two"),tracks.map{it.playableID});assertEquals("Album Artist",tracks[0].artist);assertEquals("Guest",tracks[1].artist)
        assertEquals(200.0,tracks[0].duration!!,0.0);assertEquals("MPRE1",tracks[0].json().getString("albumID"));assertEquals(2,tracks[1].json().getInt("trackNumber"))
    }
    @Test fun qualityShowsReportedStreamAndSingleQualityLimitation() {
        val info=JSONObject().put("codec","mp4a.40.2").put("bitrateKbps",129.5).put("sampleRateHz",44100).put("availableQualityCount",1)
        val value=audioDescription(info,"dataSaver")
        assertTrue(value.contains("Data saver"));assertTrue(value.contains("129 kbps"));assertTrue(value.contains("44.1 kHz"));assertTrue(value.contains("Only one source quality"))
        assertEquals("Best available · format not reported",audioDescription(null,"automatic"))
    }

    @Test fun manualSaveDuringDiscoveryWinsOverLateNetworkResponse() = kotlinx.coroutines.runBlocking {
        val started=kotlinx.coroutines.CompletableDeferred<Unit>();val response=kotlinx.coroutines.CompletableDeferred<String>()
        var automatic=true;var epoch=1;var address="https://old.trycloudflare.com"
        val task=launch { refreshDiscoveredServer(epoch,{epoch},{automatic},{started.complete(Unit);response.await()}){address=it} }
        started.await();automatic=false;epoch++;address="https://manual.example.com"
        response.complete("https://late.trycloudflare.com");task.join()
        assertEquals("https://manual.example.com",address)
    }
    @Test fun manualModeSkipsDiscoveryAndAutomaticModeAcceptsCurrentResponse() = kotlinx.coroutines.runBlocking {
        var automatic=false;var calls=0;var address="https://manual.example.com"
        val discovery: suspend ()->String={calls++;"https://fresh.trycloudflare.com"}
        refreshDiscoveredServer(1,{1},{automatic},discovery){address=it}
        assertEquals(0,calls);assertEquals("https://manual.example.com",address)
        automatic=true;refreshDiscoveredServer(1,{1},{automatic},discovery){address=it}
        assertEquals(1,calls);assertEquals("https://fresh.trycloudflare.com",address)
    }

    @Test fun directFallbackSelectsDifferentBitratesAndPreservesOriginalRecording() {
        val low=DirectAudio("https://example.com/low","m4a","mp4a",48.0,44100)
        val high=DirectAudio("https://example.com/high","m4a","mp4a",128.0,44100)
        val dubbed=DirectAudio("https://example.com/dub","m4a","mp4a",256.0,44100,false)
        val opus=DirectAudio("https://example.com/opus","webm","opus",160.0,48000)
        assertEquals(high,selectDirectAudio(listOf(low,high,dubbed,opus),"automatic"))
        assertEquals(low,selectDirectAudio(listOf(low,high,dubbed,opus),"dataSaver"))
    }
    @Test fun directFallbackHandlesOneQualityAndUnknownBitratesHonestly() {
        val only=DirectAudio("https://example.com/only","m4a",null,null,null)
        assertEquals(only,selectDirectAudio(listOf(only),"automatic"))
        assertEquals(only,selectDirectAudio(listOf(only),"dataSaver"))
    }

    @Test fun firebaseRpcMessagesStillRoundTripWithExtractorProtobufRuntime() {
        val type=Class.forName("com.google.rpc.Status")
        val builder=type.getMethod("newBuilder").invoke(null)
        builder.javaClass.getMethod("setCode",Int::class.javaPrimitiveType).invoke(builder,3)
        builder.javaClass.getMethod("setMessage",String::class.java).invoke(builder,"Fixture")
        val message=builder.javaClass.getMethod("build").invoke(builder)
        val bytes=message.javaClass.getMethod("toByteArray").invoke(message) as ByteArray
        val restored=type.getMethod("parseFrom",ByteArray::class.java).invoke(null,bytes)
        assertEquals(3,type.getMethod("getCode").invoke(restored));assertEquals("Fixture",type.getMethod("getMessage").invoke(restored))
    }

}
