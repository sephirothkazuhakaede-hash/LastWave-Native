package com.seph.capyflow

import org.junit.Assert.*
import org.junit.Test
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
        val ios=JSONObject("""{"id":"playlist-1","name":"Our songs","tracks":[{"id":"album-track","title":"Song","artist":"Artist","duration":210.5,"mediaID":"audio-video","artworkURL":"https://example.com/art.jpg","albumTitle":"Album"}]}""")
        val p=Playlist.from(ios)
        assertEquals("audio-video",p.tracks.first().playableID)
        assertEquals(p,Playlist.from(p.json()))
    }
    @Test fun songSearchDoesNotTreatMusicVideosAsAudioRecordings() {
        fun row(id:String,type:String)=JSONObject("""{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"$id"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song"}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"},{"text":"3:42"}]}}}],"navigationEndpoint":{"watchEndpoint":{"watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"$type"}}}}}}""")
        val root=JSONObject().put("audio",row("audio","MUSIC_VIDEO_TYPE_ATV")).put("video",row("video","MUSIC_VIDEO_TYPE_OMV"))
        val songs=Catalog.parseSongs(root)
        assertEquals(listOf("audio"),songs.map{it.id});assertEquals(222.0,songs.first().duration!!,0.0)
    }
}
