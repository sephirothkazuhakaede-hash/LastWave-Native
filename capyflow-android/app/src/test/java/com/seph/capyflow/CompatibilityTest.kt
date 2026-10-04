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
}
