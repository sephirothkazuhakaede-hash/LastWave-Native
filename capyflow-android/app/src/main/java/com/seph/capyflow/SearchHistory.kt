package com.seph.capyflow

import org.json.JSONArray
import org.json.JSONObject

/** Search selections stay local and retain the media IDs needed to reopen them. */
object SearchHistory {
    const val limit = 20
    fun songs(raw: String): List<Track> = entries(raw) { Track.from(it) }.distinctBy { it.playableID }.take(limit)
    fun albums(raw: String): List<Album> = entries(raw) {
        Album(it.getString("id"), it.getString("title"), it.optString("artist", "Unknown artist"), it.nullable("artwork"), it.nullable("year"))
    }.distinctBy { it.id }.take(limit)
    fun encodeSongs(values: List<Track>): String = JSONArray(values.distinctBy { it.playableID }.take(limit).map { it.json() }).toString()
    fun encodeAlbums(values: List<Album>): String = JSONArray(values.distinctBy { it.id }.take(limit).map {
        JSONObject().put("id", it.id).put("title", it.title).put("artist", it.artist).put("artwork", it.artwork).put("year", it.year)
    }).toString()
    fun rememberSong(values: List<Track>, track: Track): List<Track> = (listOf(track) + values.filterNot { it.playableID == track.playableID }).take(limit)
    fun rememberAlbum(values: List<Album>, album: Album): List<Album> = (listOf(album) + values.filterNot { it.id == album.id }).take(limit)
    private fun <T> entries(raw: String, decode: (JSONObject) -> T): List<T> {
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return (0 until array.length()).mapNotNull { index -> runCatching { decode(array.getJSONObject(index)) }.getOrNull() }
    }
}
