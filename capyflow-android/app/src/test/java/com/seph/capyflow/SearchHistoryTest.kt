package com.seph.capyflow

import org.junit.Assert.*
import org.junit.Test

class SearchHistoryTest {
    @Test fun playedSongsSurviveReloadWithArtworkAndPlaybackIdentity() {
        val song = Track("search-id", "Song", "Artist", 180.0, "https://example.com/art.jpg", "media-id", "Album", isExplicit = true)
        val restored = SearchHistory.songs(SearchHistory.encodeSongs(listOf(song))).single()
        assertEquals(song.playableID, restored.playableID)
        assertEquals(song.title, restored.title)
        assertEquals(song.artworkURL, restored.artworkURL)
        assertEquals(song.isExplicit, restored.isExplicit)
    }

    @Test fun openedAlbumsSurviveReloadWithBrowseIdentity() {
        val album = Album("browse-id", "Album", "Artist", "https://example.com/cover.jpg", "2026")
        assertEquals(listOf(album), SearchHistory.albums(SearchHistory.encodeAlbums(listOf(album))))
    }

    @Test fun replayMovesSongToFrontWithoutDuplicatesAndLimitsHistory() {
        val old = (0..25).map { Track("song-$it", "Song $it", "Artist") }
        val moved = SearchHistory.rememberSong(old, old[8].copy(title = "Updated"))
        assertEquals(20, moved.size)
        assertEquals("song-8", moved.first().playableID)
        assertEquals(1, moved.count { it.playableID == "song-8" })
        assertEquals("Updated", moved.first().title)
        assertEquals(moved.map { it.playableID }, SearchHistory.songs(SearchHistory.encodeSongs(moved)).map { it.playableID })
    }

    @Test fun malformedEntryDoesNotDiscardValidHistory() {
        assertTrue(SearchHistory.songs("invalid").isEmpty())
        val raw = """[{"broken":true},{"id":"good","title":"Song","artist":"Artist"}]"""
        assertEquals("good", SearchHistory.songs(raw).single().id)
        assertTrue(SearchHistory.albums("[]").isEmpty())
    }

    @Test fun reopeningAlbumMovesItToFrontAndRemovingStaysRemovedAfterReload() {
        val a = Album("a", "A", "Artist", null)
        val b = Album("b", "B", "Artist", null)
        val moved = SearchHistory.rememberAlbum(listOf(b, a), a)
        assertEquals(listOf(a, b), moved)
        assertEquals(listOf(b), SearchHistory.albums(SearchHistory.encodeAlbums(moved.filterNot { it.id == a.id })))
    }
}
