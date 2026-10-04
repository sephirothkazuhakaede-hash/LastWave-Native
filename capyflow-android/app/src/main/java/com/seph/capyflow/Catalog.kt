package com.seph.capyflow

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

data class Track(val id: String, val title: String, val artist: String, val duration: Double? = null,
    val artworkURL: String? = null, val mediaID: String? = null, val albumTitle: String? = null) {
    val playableID get() = mediaID ?: id
    val artwork get() = artworkURL ?: "https://i.ytimg.com/vi/$playableID/hqdefault.jpg"
    fun json() = JSONObject().put("id", id).put("title", title).put("artist", artist)
        .put("duration", duration).put("artworkURL", artworkURL).put("mediaID", mediaID).put("albumTitle", albumTitle)
    companion object {
        fun from(j: JSONObject) = Track(j.getString("id"), j.getString("title"), j.optString("artist", "Unknown artist"),
            if (j.has("duration") && !j.isNull("duration")) j.optDouble("duration") else null,
            j.nullable("artworkURL"), j.nullable("mediaID"), j.nullable("albumTitle"))
    }
}
fun JSONObject.nullable(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null

data class Playlist(val id: String, val name: String, val tracks: List<Track>) {
    fun json() = JSONObject().put("id", id).put("name", name).put("tracks", JSONArray(tracks.map { it.json() }))
    companion object { fun from(j: JSONObject) = Playlist(j.getString("id"), j.getString("name"), j.getJSONArray("tracks").let { a -> (0 until a.length()).map { Track.from(a.getJSONObject(it)) } }) }
}
data class Lyric(val time: Double?, val text: String)

class Catalog {
    val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(90, TimeUnit.SECONDS).build()
    private var version = "1.20260707.12.00"
    private var key = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private var configured = false
    suspend fun text(url: String, headers: Map<String, String> = emptyMap()): String = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url)
        headers.forEach { (k,v) -> builder.header(k,v) }
        http.newCall(builder.build()).execute().use { response ->
            check(response.isSuccessful) { "Server returned ${response.code}" }
            response.body?.string() ?: error("Server returned an empty response")
        }
    }
    suspend fun search(query: String): List<Track> = withContext(Dispatchers.IO) {
        if (!configured) {
            runCatching {
                val html = text("https://music.youtube.com/")
                Regex("\"INNERTUBE_API_KEY\"\\s*:\\s*\"([^\"]+)\"").find(html)?.groupValues?.get(1)?.let { key = it }
                Regex("\"INNERTUBE_CLIENT_VERSION\"\\s*:\\s*\"([^\"]+)\"").find(html)?.groupValues?.get(1)?.let { version = it }
            }
            configured = true
        }
        val payload = JSONObject().put("context", JSONObject().put("client", JSONObject()
            .put("clientName", "WEB_REMIX").put("clientVersion", version).put("hl", "en").put("gl", "PH")))
            .put("query", query).put("params", "EgWKAQIIAWoKEAkQBRAKEAMQBA==")
        val request = Request.Builder().url("https://music.youtube.com/youtubei/v1/search?key=$key&prettyPrint=false")
            .header("Origin", "https://music.youtube.com").header("Referer", "https://music.youtube.com/")
            .header("X-YouTube-Client-Name", "67").header("X-YouTube-Client-Version", version)
            .post(payload.toString().toRequestBody("application/json".toMediaType())).build()
        http.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "Search failed (${response.code})" }
            parseSongs(JSONObject(response.body!!.string()))
        }
    }
    suspend fun discover(): String {
        val payload = JSONObject(text("https://raw.githubusercontent.com/sephirothkazuhakaede-hash/LastWave-Native/runtime/backend-discovery/backend.json"))
        val url = payload.getString("url").trimEnd('/')
        val parsed = url.toHttpUrl()
        require(parsed.isHttps && parsed.host.endsWith(".trycloudflare.com")) { "Invalid discovery address" }
        return url
    }
    suspend fun lyrics(track: Track): List<Lyric> {
        val url = "https://lrclib.net/api/search".toHttpUrl().newBuilder()
            .addQueryParameter("track_name", track.title).addQueryParameter("artist_name", track.artist).build()
        val results = JSONArray(text(url.toString()))
        val candidates = (0 until results.length()).map { results.getJSONObject(it) }
        val selected = candidates.filter { track.duration == null || kotlin.math.abs(it.optDouble("duration") - track.duration) <= 10 }
            .minByOrNull { kotlin.math.abs(it.optDouble("duration") - (track.duration ?: it.optDouble("duration"))) }
            ?: return emptyList()
        val synced = selected.nullable("syncedLyrics")
        return if (synced != null) parseLyrics(synced) else selected.nullable("plainLyrics")?.lines()?.map { Lyric(null, it) }.orEmpty()
    }
    companion object {
        fun duration(raw: String): Double? {
            val parts = raw.split(':'); if (parts.size !in 2..3) return null
            val numbers = parts.map { it.toDoubleOrNull() ?: return null }
            if (numbers.any { it < 0 } || numbers.drop(1).any { it >= 60 }) return null
            return numbers.fold(0.0) { a, b -> a * 60 + b }
        }
        fun parseLyrics(raw: String): List<Lyric> = raw.lines().flatMap { line ->
            val matches = Regex("\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]").findAll(line).toList()
            val text = line.replace(Regex("\\[[^]]*]"), "").trim()
            matches.map { Lyric(it.groupValues[1].toDouble() * 60 + it.groupValues[2].toDouble(), text) }
        }.sortedBy { it.time }
        fun parseSongs(root: JSONObject): List<Track> {
            val tracks = linkedMapOf<String, Track>()
            fun walk(node: Any?) {
                when (node) {
                    is JSONObject -> {
                        node.optJSONObject("musicResponsiveListItemRenderer")?.let { row ->
                            val columns = row.optJSONArray("flexColumns")
                            fun runs(index: Int) = columns?.optJSONObject(index)?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")?.optJSONArray("runs") ?: JSONArray()
                            val titleRuns = runs(0)
                            val id = row.optJSONObject("playlistItemData")?.nullable("videoId")
                                ?: titleRuns.optJSONObject(0)?.optJSONObject("navigationEndpoint")?.optJSONObject("watchEndpoint")?.nullable("videoId")
                            val title = (0 until titleRuns.length()).joinToString("") { titleRuns.getJSONObject(it).optString("text") }
                            val secondary = runs(1)
                            val type = row.optJSONObject("navigationEndpoint")?.optJSONObject("watchEndpoint")?.optJSONObject("watchEndpointMusicSupportedConfigs")?.optJSONObject("watchEndpointMusicConfig")?.nullable("musicVideoType")
                            if (id != null && title.isNotBlank() && (type == null || type == "MUSIC_VIDEO_TYPE_ATV")) {
                                val artist = (0 until secondary.length()).map { secondary.getJSONObject(it) }
                                    .firstOrNull { it.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")?.optString("browseId")?.startsWith("UC") == true }?.optString("text")
                                    ?: secondary.optJSONObject(0)?.optString("text") ?: "Unknown artist"
                                val texts = (0 until (columns?.length() ?: 0)).flatMap { i -> val r = runs(i); (0 until r.length()).map { r.getJSONObject(it).optString("text") } }
                                val images = row.optJSONObject("thumbnail")?.optJSONObject("musicThumbnailRenderer")?.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
                                val art = images?.optJSONObject(images.length() - 1)?.nullable("url")
                                tracks[id] = Track(id, title, artist, texts.firstNotNullOfOrNull { duration(it) }, art)
                            }
                        }
                        node.keys().forEach { walk(node.opt(it)) }
                    }
                    is JSONArray -> (0 until node.length()).forEach { walk(node.opt(it)) }
                }
            }
            walk(root); return tracks.values.toList()
        }
    }
}
