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
    val artworkURL: String? = null, val mediaID: String? = null, val albumTitle: String? = null, val originalPayload: String? = null, val isExplicit: Boolean? = null) {
    val playableID get() = mediaID ?: id
    val artwork get() = artworkURL ?: "https://i.ytimg.com/vi/$playableID/hqdefault.jpg"
    fun json() = (originalPayload?.let { JSONObject(it) } ?: JSONObject()).put("id", id).put("title", title).put("artist", artist)
        .put("duration", duration).put("artworkURL", artworkURL).put("mediaID", mediaID).put("albumTitle", albumTitle).put("isExplicit", isExplicit ?: JSONObject.NULL)
    companion object {
        fun from(j: JSONObject) = Track(j.getString("id"), j.getString("title"), j.optString("artist", "Unknown artist"),
            if (j.has("duration") && !j.isNull("duration")) j.optDouble("duration") else null,
            j.nullable("artworkURL"), j.nullable("mediaID"), j.nullable("albumTitle"), j.toString(), if(j.isNull("isExplicit"))null else j.optBoolean("isExplicit"))
    }
}
fun JSONObject.nullable(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null

data class Playlist(val id: String, val name: String, val tracks: List<Track>, val artworkURL: String? = null, val albumID: String? = null, val originalPayload: String? = null, val ownerID: String? = null) {
    fun json() = (originalPayload?.let{JSONObject(it)} ?: JSONObject()).put("id", id).put("name", name).put("tracks", JSONArray(tracks.map { it.json() })).put("artworkURL",artworkURL).put("albumID",albumID).put("ownerID",ownerID)
    companion object { fun from(j: JSONObject) = Playlist(j.getString("id"), j.getString("name"), j.getJSONArray("tracks").let { a -> (0 until a.length()).map { Track.from(a.getJSONObject(it)) } },j.nullable("artworkURL"),j.nullable("albumID"),j.toString(),j.nullable("ownerID")) }
}
data class Album(val id: String, val title: String, val artist: String, val artwork: String?, val year: String? = null)
data class Lyric(val time: Double?, val text: String)

class Catalog {
    val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(90, TimeUnit.SECONDS).build()
    private var version = "1.20260707.12.00"
    private var key = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private var configured = false
    suspend fun text(url: String, headers: Map<String, String> = emptyMap(), timeoutSeconds: Long = 90): String = kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
        val builder=Request.Builder().url(url);headers.forEach{(k,v)->builder.header(k,v)}
        val call=http.newCall(builder.build());call.timeout().timeout(timeoutSeconds,TimeUnit.SECONDS)
        continuation.invokeOnCancellation{call.cancel()}
        call.enqueue(object: okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call,e: java.io.IOException){if(continuation.isActive)continuation.resumeWith(Result.failure(e))}
            override fun onResponse(call: okhttp3.Call,response: okhttp3.Response){response.use{r -> val result=runCatching{if(!r.isSuccessful)throw HttpResponseException(r.code);r.body?.string() ?: error("Server returned an empty response")};if(continuation.isActive)continuation.resumeWith(result)}}
        })
    }
    suspend fun search(query: String): List<Track> = parseSongs(searchResponse(query, "EgWKAQIIAWoKEAkQBRAKEAMQBA=="))
    suspend fun searchAlbums(query: String): List<Album> = parseAlbums(searchResponse(query, "EgWKAQIYAWoKEAkQChAFEAMQBA=="))
    private suspend fun searchResponse(query: String, params: String): JSONObject = withContext(Dispatchers.IO) {
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
            .put("query", query).put("params", params)
        val request = Request.Builder().url("https://music.youtube.com/youtubei/v1/search?key=$key&prettyPrint=false")
            .header("Origin", "https://music.youtube.com").header("Referer", "https://music.youtube.com/")
            .header("X-YouTube-Client-Name", "67").header("X-YouTube-Client-Version", version)
            .post(payload.toString().toRequestBody("application/json".toMediaType())).build()
        http.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "Search failed (${response.code})" }
            JSONObject(response.body!!.string())
        }
    }
    suspend fun discover():String = discoverWithRetry {
        val url="https://raw.githubusercontent.com/sephirothkazuhakaede-hash/LastWave-Native/runtime/backend-discovery/backend.json".toHttpUrl().newBuilder()
            .addQueryParameter("refresh",java.util.UUID.randomUUID().toString()).build()
        val payload=JSONObject(text(url.toString(),mapOf("Cache-Control" to "no-cache, no-store","Pragma" to "no-cache"),8))
        val address=payload.getString("url").trimEnd('/');val parsed=address.toHttpUrl()
        require(parsed.isHttps && parsed.host.endsWith(".trycloudflare.com") && parsed.username.isEmpty() && parsed.password.isEmpty() && parsed.query==null && parsed.fragment==null && parsed.port==443){"Invalid discovery address"}
        address
    }
    suspend fun albumTracks(album: Album): List<Track> = withContext(Dispatchers.IO) {
        val payload=JSONObject().put("context",JSONObject().put("client",JSONObject().put("clientName","WEB_REMIX").put("clientVersion",version).put("hl","en").put("gl","PH"))).put("browseId",album.id)
        val request=Request.Builder().url("https://music.youtube.com/youtubei/v1/browse?key=$key&prettyPrint=false").header("Origin","https://music.youtube.com").header("X-YouTube-Client-Name","67").header("X-YouTube-Client-Version",version).post(payload.toString().toRequestBody("application/json".toMediaType())).build()
        http.newCall(request).execute().use { r -> check(r.isSuccessful){"Album could not load (${r.code})"}; parseAlbumTracks(JSONObject(r.body!!.string()),album) }
    }
    suspend fun backendLyrics(track: Track, base: String, headers: Map<String,String>): List<Lyric> {
        val url="$base/lyrics".toHttpUrl().newBuilder().addQueryParameter("title",track.title).addQueryParameter("artist",track.artist).addQueryParameter("videoId",track.playableID).apply { track.albumTitle?.let { addQueryParameter("album",it) };track.duration?.let { addQueryParameter("duration",it.toString()) } }.build()
        val json=JSONObject(text(url.toString(),headers,12));if(json.optString("synchronization") !in setOf("plain","line","word","syllable"))return emptyList();val lines=json.optJSONArray("lines") ?: return emptyList()
        return (0 until lines.length()).mapNotNull { i -> val l=lines.getJSONObject(i);val t=l.optString("text").trim();if(t.isBlank())null else Lyric(if(l.isNull("time"))null else l.optDouble("time").takeIf{it.isFinite()},t) }
    }
    suspend fun communityLyrics(track: Track): List<Lyric> {
        // Match the exact media ID; never estimate timestamps for plain lyrics.
        if(!Regex("[A-Za-z0-9_-]{11}").matches(track.playableID)) return emptyList()
        val response=JSONObject(text("https://api-lyrics.simpmusic.org/v1/${track.playableID}",mapOf("User-Agent" to "CapyFlow-Android"),12))
        if(!response.optBoolean("success")) return emptyList()
        val records=response.optJSONArray("data") ?: return emptyList()
        for(i in 0 until records.length()) {
            val record=records.optJSONObject(i) ?: continue
            val id=record.nullable("videoId")
            if(id!=null && id!=track.playableID) continue
            val duration=record.optDouble("duration")
            if(track.duration!=null && duration.isFinite() && duration>0 && kotlin.math.abs(duration-track.duration)>12) continue
            val synced=record.nullable("syncedLyrics")?.takeIf{it.isNotBlank()} ?: continue
            val lines=parseLyrics(synced)
            if(lines.any{it.time!=null}) return lines
        }
        return emptyList()
    }
    suspend fun lyrics(track: Track): List<Lyric> {
        val headers=mapOf("User-Agent" to "CapyFlow-Android/0.1 (lyrics lookup)")
        var plain=emptyList<Lyric>()
        val exact="https://lrclib.net/api/get".toHttpUrl().newBuilder().addQueryParameter("track_name",cleanTitle(track.title)).addQueryParameter("artist_name",track.artist).apply{track.albumTitle?.let{addQueryParameter("album_name",it)};track.duration?.let{addQueryParameter("duration",it.toString())}}.build()
        try{val candidate=selectLyrics(JSONArray().put(JSONObject(text(exact.toString(),headers,10))),track);if(candidate.any{it.time!=null})return candidate;plain=candidate}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(_:Exception){}
        val urls=listOf(
            "https://lrclib.net/api/search".toHttpUrl().newBuilder().addQueryParameter("track_name",cleanTitle(track.title)).addQueryParameter("artist_name",track.artist).build(),
            "https://lrclib.net/api/search".toHttpUrl().newBuilder().addQueryParameter("q",cleanTitle(track.title)+" "+track.artist).build())
        for(url in urls)try{val candidate=selectLyrics(JSONArray(text(url.toString(),headers,10)),track);if(candidate.any{it.time!=null})return candidate;if(plain.isEmpty())plain=candidate}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(_:Exception){}
        return plain
    }
    companion object {
        fun cleanTitle(title: String) = title.replace(Regex("(?i)\\s*[(\\[](?:official(?: music)? (?:audio|video)|lyrics?|audio|visualizer)[)\\]]"), "").trim()
        private fun normalized(value: String)=cleanTitle(value).lowercase().filter { it.isLetterOrDigit() }
        fun selectLyrics(results: JSONArray, track: Track): List<Lyric> {
            val candidates=(0 until results.length()).map { results.getJSONObject(it) }.filter {
                normalized(it.optString("trackName"))==normalized(track.title) && normalized(it.optString("artistName"))==normalized(track.artist) &&
                (track.duration==null || kotlin.math.abs(it.optDouble("duration")-track.duration)<=maxOf(5.0,minOf(12.0,track.duration*.04))) &&
                (!it.nullable("syncedLyrics").isNullOrBlank() || !it.nullable("plainLyrics").isNullOrBlank())
            }
            val chosen=candidates.maxByOrNull { (if(!it.nullable("syncedLyrics").isNullOrBlank())20.0 else 0.0)-kotlin.math.abs(it.optDouble("duration")-(track.duration ?: it.optDouble("duration"))) } ?: return emptyList()
            return chosen.nullable("syncedLyrics")?.takeIf { it.isNotBlank() }?.let { parseLyrics(it) } ?: chosen.nullable("plainLyrics").orEmpty().lines().filter { it.isNotBlank() }.map { Lyric(null,it) }
        }
        fun encodeLyrics(lines: List<Lyric>)=JSONArray(lines.map { JSONObject().put("time",it.time ?: JSONObject.NULL).put("text",it.text) }).toString()
        fun decodeLyrics(raw: String): List<Lyric> { val a=JSONArray(raw);return (0 until a.length()).map { val l=a.getJSONObject(it);Lyric(if(l.isNull("time"))null else l.getDouble("time"),l.getString("text")) } }
        fun artworkForDisplay(url: String, size: Int = 1200): String {
            val uri=runCatching { url.toHttpUrl() }.getOrNull() ?: return url
            if(uri.query!=null || uri.host !in setOf("lh3.googleusercontent.com","lh4.googleusercontent.com","yt3.ggpht.com","yt3.googleusercontent.com"))return url
            return url.replace(Regex("=w\\d+-h\\d+"),"=w$size-h$size").replace(Regex("=s\\d+"),"=s$size")
        }
        private fun walkObjects(node: Any?, visit: (JSONObject)->Unit) {
            when(node) { is JSONObject -> { visit(node);node.keys().forEach { walkObjects(node.opt(it),visit) } };is JSONArray -> (0 until node.length()).forEach { walkObjects(node.opt(it),visit) } }
        }
        private fun rendered(text: JSONObject?): String = text?.optString("simpleText")?.takeIf{it.isNotBlank()} ?: text?.optJSONArray("runs")?.let { a -> (0 until a.length()).joinToString("") { a.getJSONObject(it).optString("text") } }.orEmpty()
        private fun columns(row: JSONObject): List<JSONObject?> = row.optJSONArray("flexColumns")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text") } }.orEmpty()
        private fun rowArtwork(row: JSONObject): String? { val a=row.optJSONObject("thumbnail")?.optJSONObject("musicThumbnailRenderer")?.optJSONObject("thumbnail")?.optJSONArray("thumbnails") ?: return null;return (0 until a.length()).map { a.getJSONObject(it) }.maxByOrNull { it.optLong("width")*it.optLong("height") }?.nullable("url") }
        fun explicitBadge(row: JSONObject): Boolean {
            var explicit=false
            walkObjects(row.opt("badges")){node -> if(node.optJSONObject("icon")?.optString("iconType")=="MUSIC_EXPLICIT_BADGE")explicit=true}
            return explicit
        }
        fun parseAlbums(root: JSONObject): List<Album> {
            val albums=linkedMapOf<String,Album>();walkObjects(root) { node -> node.optJSONObject("musicResponsiveListItemRenderer")?.let { row ->
                val c=columns(row);var id=row.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")?.nullable("browseId");var artist="Unknown artist"
                c.forEach { text -> text?.optJSONArray("runs")?.let { runs -> (0 until runs.length()).forEach { i -> val r=runs.getJSONObject(i);val browse=r.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")?.nullable("browseId");if(browse?.startsWith("MPRE")==true)id=browse;if(browse?.startsWith("UC")==true)artist=r.optString("text") } } }
                val title=rendered(c.getOrNull(0));if(id?.startsWith("MPRE")==true && title.isNotBlank())albums.putIfAbsent(id!!,Album(id!!,title,artist,rowArtwork(row),Regex("\\b(?:19|20)\\d{2}\\b").find(c.joinToString(" "){rendered(it)})?.value))
            } };return albums.values.toList()
        }
        fun parseAlbumTracks(root: JSONObject, album: Album): List<Track> {
            val tracks=linkedMapOf<String,Track>();walkObjects(root) { node -> node.optJSONObject("musicResponsiveListItemRenderer")?.let { row ->
                val id=row.optJSONObject("playlistItemData")?.nullable("videoId");val c=columns(row);val title=rendered(c.getOrNull(0))
                if(id!=null && row.has("index") && title.isNotBlank()) { val fixed=row.optJSONArray("fixedColumns")?.optJSONObject(0)?.optJSONObject("musicResponsiveListItemFixedColumnRenderer")?.optJSONObject("text");val payload=JSONObject().put("id",id).put("albumID",album.id).put("trackNumber",rendered(row.optJSONObject("index")).toIntOrNull());tracks.putIfAbsent(id,Track(id,title,rendered(c.getOrNull(1)).ifBlank { album.artist },duration(rendered(fixed)),rowArtwork(row) ?: album.artwork,albumTitle=album.title,originalPayload=payload.toString(),isExplicit=explicitBadge(row))) }
            } };return tracks.values.toList()
        }
        fun duration(raw: String): Double? {
            val parts = raw.split(':'); if (parts.size !in 2..3) return null
            val numbers = parts.map { it.toDoubleOrNull() ?: return null }
            if (numbers.any { it < 0 } || numbers.drop(1).any { it >= 60 }) return null
            return numbers.fold(0.0) { a, b -> a * 60 + b }
        }
        fun parseLyrics(raw: String): List<Lyric> = raw.lines().flatMap { line ->
            val matches = Regex("\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]").findAll(line).toList()
            val text = line.replace(Regex("\\[[^]]*]"), "").trim()
            matches.filter { text.isNotBlank() }.map { Lyric(it.groupValues[1].toDouble() * 60 + it.groupValues[2].toDouble(), text) }
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
                                tracks[id] = Track(id, title, artist, texts.firstNotNullOfOrNull { duration(it) }, art,isExplicit=explicitBadge(row))
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
