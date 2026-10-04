package com.seph.capyflow

import android.app.Application
import android.content.ComponentName
import android.net.Uri
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.PlaybackException
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.core.content.ContextCompat
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.*
import kotlinx.coroutines.*
import kotlinx.coroutines.tasks.await
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class CapyModel(app: Application) : AndroidViewModel(app) {
    val catalog = Catalog()
    private val prefs = app.getSharedPreferences("capyflow", 0)
    val auth: FirebaseAuth? = if (BuildConfig.FIREBASE_CONFIGURED) FirebaseAuth.getInstance() else null
    val db: FirebaseFirestore? = if (BuildConfig.FIREBASE_CONFIGURED) FirebaseFirestore.getInstance() else null
    var user by mutableStateOf(auth?.currentUser); private set
    var results by mutableStateOf<List<Track>>(emptyList()); private set
    var searching by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)
    var current by mutableStateOf<Track?>(null); private set
    var playing by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var elapsed by mutableDoubleStateOf(0.0); private set
    var duration by mutableDoubleStateOf(0.0); private set
    var queue by mutableStateOf<List<Track>>(emptyList()); private set
    var lyrics by mutableStateOf<List<Lyric>>(emptyList()); private set
    var lyricsLoading by mutableStateOf(false); private set
    var playlists by mutableStateOf<List<Playlist>>(emptyList()); private set
    var downloads by mutableStateOf<List<Track>>(emptyList()); private set
    var downloading by mutableStateOf<Set<String>>(emptySet()); private set
    var server by mutableStateOf(prefs.getString("server", "") ?: ""); private set
    var quality by mutableStateOf(prefs.getString("quality", "automatic") ?: "automatic"); private set
    var cloudStatus by mutableStateOf("Sign in to back up playlists"); private set
    private var controller: MediaController? = null
    private val controllerFuture = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
    private var searchJob: Job? = null
    private var playJob: Job? = null
    private var lyricJob: Job? = null
    private var libraryListener: ListenerRegistration? = null
    private var accountEpoch = 0
    private var owner = auth?.currentUser?.uid ?: "guest"
    private val authListener = FirebaseAuth.AuthStateListener { a ->
        if (owner != (a.currentUser?.uid ?: "guest")) {
            accountEpoch++; libraryListener?.remove(); owner = a.currentUser?.uid ?: "guest"
            playlists = readPlaylists(); PlaybackAuthorization.token = null
        }
        user = a.currentUser; bindCloud()
    }
    init {
        playlists = readPlaylists()
        downloads = runCatching { readArray("downloads").let { a -> (0 until a.length()).map { Track.from(a.getJSONObject(it)) } } }.getOrDefault(emptyList())
            .filter { downloadedFile(it).exists() }
        controllerFuture.addListener({
            runCatching { controllerFuture.get() }.onSuccess { c ->
                controller = c
                c.addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(isPlaying: Boolean) { playing = isPlaying }
                    override fun onPlaybackStateChanged(state: Int) {
                        loading = state == Player.STATE_BUFFERING
                        if (state == Player.STATE_ENDED) next()
                    }
                    override fun onPlayerError(e: PlaybackException) { error = "Playback failed: ${e.message}"; loading = false }
                })
                c.currentMediaItem?.let { item -> current = Track(item.mediaId, item.mediaMetadata.title.toString(), item.mediaMetadata.artist.toString(), artworkURL = item.mediaMetadata.artworkUri?.toString()) }
            }.onFailure { error = "Player could not start: ${it.message}" }
        }, ContextCompat.getMainExecutor(app))
        auth?.addAuthStateListener(authListener)
        viewModelScope.launch { while (isActive) { controller?.let { c -> elapsed = c.currentPosition.coerceAtLeast(0) / 1000.0; if (c.duration > 0) duration = c.duration / 1000.0 }; delay(300) } }
    }
    private fun readArray(key: String) = JSONArray(prefs.getString(key, "[]"))
    private fun readPlaylists() = runCatching { readArray("library.$owner").let { a -> (0 until a.length()).map { Playlist.from(a.getJSONObject(it)) } } }.getOrDefault(emptyList())
    private fun persistLibrary() { prefs.edit().putString("library.$owner", JSONArray(playlists.map { it.json() }).toString()).apply() }
    fun search(query: String) {
        searchJob?.cancel(); if (query.isBlank()) { results = emptyList(); searching = false; return }
        searchJob = viewModelScope.launch {
            searching = true; error = null
            try { results = catalog.search(query.trim()) } catch (e: CancellationException) { throw e } catch(e: Exception) { error = e.message }
            finally { searching = false }
        }
    }
    fun saveServer(value: String) {
        runCatching { val url = value.trim().trimEnd('/').toHttpUrl(); require(url.isHttps && url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null) { "Enter a complete HTTPS server address" }; server = url.toString().trimEnd('/'); prefs.edit().putString("server", server).apply() }.onFailure { error = it.message }
    }
    fun saveQuality(value: String) { quality = value; prefs.edit().putString("quality", value).apply() }
    private suspend fun base(): String {
        if (server.isBlank() || server.toHttpUrl().host.endsWith(".trycloudflare.com")) {
            runCatching { catalog.discover() }.onSuccess { server = it; prefs.edit().putString("server", it).apply() }
        }
        check(server.isNotBlank()) { "Streaming server is unavailable. Open Settings and enter your server address." }
        return server.trimEnd('/').let { if (it.endsWith("/v1")) it else "$it/v1" }
    }
    private suspend fun resolve(track: Track): Pair<String, Map<String,String>> {
        val base = base()
        val token = auth?.currentUser?.getIdToken(false)?.await()?.token
        val headers = token?.let { mapOf("Authorization" to "Bearer $it") }.orEmpty()
        PlaybackAuthorization.host = base.toHttpUrl().host; PlaybackAuthorization.token = token
        val metadata = JSONObject(catalog.text("$base/resolve/${track.playableID}?quality=$quality", headers))
        if (current?.id == track.id && metadata.optDouble("duration", 0.0) > 0) duration = metadata.getDouble("duration")
        return Pair("$base/audio/${track.playableID}?quality=$quality", headers)
    }
    fun play(track: Track, following: List<Track>? = null) {
        playJob?.cancel(); lyricJob?.cancel(); controller?.pause()
        current = track; elapsed = 0.0; duration = track.duration ?: 0.0; lyrics = emptyList(); loading = true
        if (following != null) queue = following.dropWhile { it.id != track.id }.drop(1)
        playJob = viewModelScope.launch {
            try {
                val file = downloadedFile(track)
                val uri = if (file.exists()) Uri.fromFile(file) else Uri.parse(resolve(track).first)
                val c = controller ?: error("Player is starting. Try again in a moment.")
                c.setMediaItem(MediaItem.Builder().setMediaId(track.id).setUri(uri).setMediaMetadata(MediaMetadata.Builder()
                    .setTitle(track.title).setArtist(track.artist).setArtworkUri(Uri.parse(track.artwork)).build()).build())
                c.prepare(); c.play()
                loadLyrics(track)
            } catch (e: CancellationException) { throw e } catch (e: Exception) { error = e.message; loading = false }
        }
    }
    private fun loadLyrics(track: Track) {
        lyricJob = viewModelScope.launch { lyricsLoading = true
            try { lyrics = catalog.lyrics(track) } catch(e: CancellationException) { throw e } catch (_: Exception) { lyrics = emptyList() }
            finally { lyricsLoading = false }
        }
    }
    fun toggle() { controller?.let { if (it.isPlaying) it.pause() else it.play() } }
    fun seek(seconds: Double) { controller?.seekTo((seconds.coerceAtLeast(0.0) * 1000).toLong()) }
    fun next() { if (queue.isNotEmpty()) { val t = queue.first(); queue = queue.drop(1); play(t) } }
    fun previous() { seek(0.0) }
    fun enqueue(track: Track) { queue = queue + track }
    fun removeQueue(index: Int) { queue = queue.filterIndexed { i, _ -> i != index } }
    fun moveQueue(index: Int, delta: Int) { val target = index + delta; if (target !in queue.indices) return; val list = queue.toMutableList(); val item = list.removeAt(index); list.add(target, item); queue = list }
    fun clearQueue() { queue = emptyList() }
    private fun safeID(id: String) = MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).joinToString("") { "%02x".format(it) }
    fun downloadedFile(track: Track) = File(getApplication<Application>().filesDir, "downloads/${safeID(track.playableID)}.audio")
    fun download(track: Track) {
        if (track.id in downloading || downloads.any { it.id == track.id }) return
        downloading = downloading + track.id
        viewModelScope.launch {
            val destination = downloadedFile(track); val partial = File(destination.path + ".part")
            try {
                val (url, headers) = resolve(track)
                withContext(Dispatchers.IO) {
                    destination.parentFile!!.mkdirs()
                    val request = Request.Builder().url(url.replace("/audio/", "/download/")); headers.forEach { (k,v) -> request.header(k,v) }
                    catalog.http.newCall(request.build()).execute().use { response ->
                        check(response.isSuccessful) { "Download failed (${response.code})" }
                        check(response.header("Content-Type")?.contains("json") != true) { "Server did not return audio" }
                        response.body!!.byteStream().use { input -> partial.outputStream().use { input.copyTo(it) } }
                    }
                    check(partial.length() > 0 && partial.renameTo(destination)) { "Could not save download" }
                }
                downloads = downloads.filterNot { it.id == track.id } + track
                prefs.edit().putString("downloads", JSONArray(downloads.map { it.json() }).toString()).apply()
            } catch(e: CancellationException) { throw e } catch (e: Exception) { error = e.message }
            finally { partial.delete(); downloading = downloading - track.id }
        }
    }
    fun removeDownload(track: Track) { if (downloadedFile(track).delete()) { downloads = downloads.filterNot { it.id == track.id }; prefs.edit().putString("downloads", JSONArray(downloads.map { it.json() }).toString()).apply() } }
    fun createPlaylist(name: String) { if (name.trim().isEmpty()) return; val p = Playlist(UUID.randomUUID().toString(), name.trim(), emptyList()); playlists = playlists + p; persistLibrary(); sync(p) }
    fun addToPlaylist(id: String, track: Track) { val p = playlists.firstOrNull { it.id == id } ?: return; if (p.tracks.any { it.id == track.id }) return; val updated = p.copy(tracks = p.tracks + track); playlists = playlists.map { if (it.id == id) updated else it }; persistLibrary(); sync(updated) }
    fun removeFromPlaylist(id: String, trackID: String) { val p = playlists.firstOrNull { it.id == id } ?: return; val updated = p.copy(tracks = p.tracks.filterNot { it.id == trackID }); playlists = playlists.map { if(it.id == id) updated else it }; persistLibrary(); sync(updated) }
    fun deletePlaylist(id: String) { playlists = playlists.filterNot { it.id == id }; persistLibrary(); sync(null, id) }
    private fun sync(playlist: Playlist?, id: String = playlist!!.id) {
        if (user == null || db == null) return
        val fields = mutableMapOf<String,Any>("playlistID" to id, "deleted" to (playlist == null), "updatedAt" to FieldValue.serverTimestamp())
        playlist?.let { val bytes = it.json().toString().toByteArray(); if(bytes.size > 750000) { error = "Playlist is too large for cloud backup"; return }; fields["payload"] = Blob.fromBytes(bytes) }
        // Durable pending records survive offline edits and process restarts.
        val pendingValue = playlist?.json()?.toString() ?: "deleted"
        prefs.edit().putString("pending.$owner.$id", pendingValue).commit()
        val epoch = accountEpoch; val uid = owner
        db.collection("users").document(uid).collection("library").document(safeID(id)).set(fields)
            .addOnSuccessListener { if(prefs.getString("pending.$uid.$id", null) == pendingValue) prefs.edit().remove("pending.$uid.$id").apply(); if(epoch == accountEpoch) cloudStatus = "Playlists backed up" }
            .addOnFailureListener { if(epoch == accountEpoch) { cloudStatus = "Backup pending"; error = it.message } }
    }
    private fun bindCloud() {
        libraryListener?.remove(); val uid = user?.uid ?: run { cloudStatus = "Sign in to back up playlists"; return }
        val database = db ?: return; cloudStatus = "Syncing playlists…"; val epoch = accountEpoch
        prefs.all.filterKeys { it.startsWith("pending.$uid.") }.forEach { (key, value) -> val id = key.removePrefix("pending.$uid."); if(value == "deleted") sync(null,id) else runCatching { sync(Playlist.from(JSONObject(value.toString()))) } }
        libraryListener = database.collection("users").document(uid).collection("library").addSnapshotListener { snapshot, failure ->
            if(epoch != accountEpoch) return@addSnapshotListener
            if(failure != null) { cloudStatus = "Backup unavailable"; error = failure.message; return@addSnapshotListener }
            if(snapshot != null) {
                var merged = playlists.associateBy { it.id }.toMutableMap()
                snapshot.documents.forEach { d -> val id = d.getString("playlistID") ?: return@forEach
                    if(prefs.contains("pending.$uid.$id")) return@forEach
                    if(d.getBoolean("deleted") == true) merged.remove(id)
                    else d.getBlob("payload")?.toBytes()?.let { bytes -> runCatching { Playlist.from(JSONObject(String(bytes))) }.onSuccess { merged[id] = it } }
                }
                playlists = merged.values.toList(); persistLibrary(); cloudStatus = if(snapshot.metadata.isFromCache) "Offline library" else "Playlists backed up"
            }
        }
    }
    fun signOut() { auth?.signOut() }
    override fun onCleared() { libraryListener?.remove(); auth?.removeAuthStateListener(authListener); MediaController.releaseFuture(controllerFuture); super.onCleared() }
}
