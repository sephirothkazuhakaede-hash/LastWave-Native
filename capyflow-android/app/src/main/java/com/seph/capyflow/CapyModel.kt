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
    var albums by mutableStateOf<List<Album>>(emptyList()); private set
    var albumTracks by mutableStateOf<List<Track>>(emptyList()); private set
    var albumLoading by mutableStateOf(false); private set
    var lyricsError by mutableStateOf<String?>(null); private set
    private var searchEpoch=0
    private var albumEpoch=0
    private var lyricEpoch=0
    private var albumJob: Job?=null
    private var usingLocalPlayback=false
    private var recoveringPlayback=false
    private var usingDirectPlayback=false
    private var backendRetryAfter=0L
    var searching by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null)
    var current by mutableStateOf<Track?>(null); private set
    var audioDetails by mutableStateOf("Not playing"); private set
    private val downloadingIDs=mutableSetOf<String>()
    private val downloadSlots=kotlinx.coroutines.sync.Semaphore(2)
    var playing by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var elapsed by mutableDoubleStateOf(0.0); private set
    var duration by mutableDoubleStateOf(0.0); private set
    private var queueEntries by mutableStateOf<List<QueueEntry>>(emptyList())
    val queue get() = queueEntries.map{it.track}
    val queueKeys get() = queueEntries.map{it.key}
    var lyrics by mutableStateOf<List<Lyric>>(emptyList()); private set
    var lyricsLoading by mutableStateOf(false); private set
    var playlists by mutableStateOf<List<Playlist>>(emptyList()); private set
    var recentTracks by mutableStateOf<List<Track>>(emptyList()); private set
    var downloadFailures by mutableStateOf<Map<String,String>>(emptyMap()); private set
    private var previousTracks=emptyList<Track>()
    private val lyricLocks=mutableMapOf<String,kotlinx.coroutines.sync.Mutex>()
    private val lyricRefreshAt=mutableMapOf<String,Long>()
    var downloads by mutableStateOf<List<Track>>(emptyList()); private set
    var downloading by mutableStateOf<Set<String>>(emptySet()); private set
    var server by mutableStateOf(prefs.getString("server", "") ?: ""); private set
    var automaticServer by mutableStateOf(prefs.getBoolean("automaticServer",server.isBlank() || runCatching{server.toHttpUrl().host.endsWith(".trycloudflare.com")}.getOrDefault(false))); private set
    var serverStatus by mutableStateOf(""); private set
    var serverBusy by mutableStateOf(false); private set
    private var connectionJob:Job?=null
    private var serverEpoch=0
    private var lastDiscoveryMs=0L
    var quality by mutableStateOf(prefs.getString("quality", "automatic") ?: "automatic"); private set
    var cloudStatus by mutableStateOf("Sign in to save playlists across devices"); private set
    private var controller: MediaController? = null
    private val controllerFuture = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
    private var searchJob: Job? = null
    var collaboration: SocialModel? = null
    private var sharedSources: Map<String,SharedCollection> = emptyMap()
    fun applySharedCollections(shared: List<SharedCollection>) {
        sharedSources=shared.filter{it.ownerID==user?.uid && !it.sourceID.startsWith("cloud:")}.associateBy{it.sourceID}
        var changed=false
        sharedSources.forEach{(id,item) ->
            val old=playlists.firstOrNull{it.id==id}
            val updated=(old ?: Playlist(id,item.name,emptyList(),ownerID=item.ownerID)).copy(name=item.name,tracks=item.tracks,ownerID=item.ownerID)
            if(old?.json()?.toString()!=updated.json().toString()){
                playlists=playlists.filterNot{it.id==id}+updated;sync(updated);changed=true
            }
        }
        if(changed)persistLibrary()
    }
    fun keepPersonalCopy(shared:SharedCollection){
        if(shared.ownerID!=user?.uid)return
        sharedSources=sharedSources-shared.sourceID
        val old=playlists.firstOrNull{it.id==shared.sourceID}
        val updated=(old ?: Playlist(shared.sourceID,shared.name,emptyList(),ownerID=shared.ownerID)).copy(name=shared.name,tracks=shared.tracks)
        playlists=playlists.filterNot{it.id==updated.id}+updated;persistLibrary();sync(updated)
    }
    private var playJob: Job? = null
    private var startupWatchdog:Job?=null
    private var resolvingPlayback=false
    private var lyricJob: Job? = null
    private var libraryListener: ListenerRegistration? = null
    private var accountEpoch = 0
    private var owner = auth?.currentUser?.uid ?: "guest"
    private val authListener = FirebaseAuth.AuthStateListener { a ->
        user = a.currentUser
        if (owner != (a.currentUser?.uid ?: "guest")) {
            accountEpoch++; sharedSources=emptyMap(); libraryListener?.remove(); owner = a.currentUser?.uid ?: "guest"
            playlists = readPlaylists(); PlaybackAuthorization.token = null
            if(owner!="guest" && !prefs.contains("guestImportedTo")) {
                val guest=runCatching{JSONArray(prefs.getString("library.guest","[]")).let{a -> (0 until a.length()).map{Playlist.from(a.getJSONObject(it))}}}.getOrDefault(emptyList())
                if(guest.isNotEmpty()){playlists=(playlists+guest).distinctBy{it.id};persistLibrary();guest.forEach{sync(it)};prefs.edit().putString("guestImportedTo",owner).apply()}
            }
        }
        user = a.currentUser; bindCloud()
    }
    init {
        playlists = readPlaylists()
        recentTracks=runCatching{readArray("recentTracks").let{a -> (0 until a.length()).map{Track.from(a.getJSONObject(it))}}}.getOrDefault(emptyList())
        downloadFailures=runCatching{JSONObject(prefs.getString("downloadFailures","{}")!!).let{j -> j.keys().asSequence().associateWith{j.getString(it)}}}.getOrDefault(emptyMap())
        downloads = runCatching { readArray("downloads").let { a -> (0 until a.length()).map { Track.from(a.getJSONObject(it)) } } }.getOrDefault(emptyList())
            .filter { downloadedFile(it).exists() }
        controllerFuture.addListener({
            runCatching { controllerFuture.get() }.onSuccess { c ->
                controller = c
                c.addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(isPlaying: Boolean) { playing = isPlaying
                        if(isPlaying)current?.let{track -> recentTracks=(listOf(track)+recentTracks.filterNot{it.playableID==track.playableID}).take(40);prefs.edit().putString("recentTracks",JSONArray(recentTracks.map{it.json()}).toString()).apply()}
                    }
                    override fun onPlaybackStateChanged(state: Int) {
                        loading = resolvingPlayback || state == Player.STATE_BUFFERING
                        if (state == Player.STATE_ENDED) next()
                    }
                    override fun onPlayerError(e: PlaybackException) {
                        if(resolvingPlayback)return
                        val track=current
                        if(track!=null && !recoveringPlayback && (usingLocalPlayback || e.errorCode in 2000..2999)) {
                            play(track,recovering=true,resumeAt=elapsed,preferDirect=!usingLocalPlayback && !usingDirectPlayback)
                        } else { error=if(usingLocalPlayback)"This saved audio couldn’t play. Your download has been kept. Try again, or remove it from Downloads and download it again when online." else "Playback couldn’t continue. Check your connection and server, then try again. (${e.errorCodeName})";loading=false }
                    }
                })
                c.currentMediaItem?.takeIf{current==null}?.let { item -> current = Track(item.mediaId, item.mediaMetadata.title.toString(), item.mediaMetadata.artist.toString(), artworkURL = item.mediaMetadata.artworkUri?.toString()) }
            }.onFailure { error = "Couldn’t start the player. Please reopen CapyFlow and try again." }
        }, ContextCompat.getMainExecutor(app))
        auth?.addAuthStateListener(authListener)
        viewModelScope.launch { while (isActive) { controller?.let { c -> elapsed = c.currentPosition.coerceAtLeast(0) / 1000.0; if (c.duration > 0) duration = c.duration / 1000.0 }; delay(300) } }
    }
    private fun readArray(key: String) = JSONArray(prefs.getString(key, "[]"))
    private fun readPlaylists() = runCatching { readArray("library.$owner").let { a -> (0 until a.length()).map { Playlist.from(a.getJSONObject(it)) } } }.getOrDefault(emptyList())
    private fun persistLibrary() { prefs.edit().putString("library.$owner", JSONArray(playlists.map { it.json() }).toString()).apply() }
    fun search(query: String, albumsOnly: Boolean=false) {
        searchJob?.cancel();val epoch=++searchEpoch;results=emptyList();albums=emptyList();searching=false
        if(query.isBlank())return
        searchJob=viewModelScope.launch { searching=true;error=null
            try { if(albumsOnly) { val found=catalog.searchAlbums(query.trim());ensureActive();if(epoch==searchEpoch)albums=found } else { val found=catalog.search(query.trim());ensureActive();if(epoch==searchEpoch)results=found } }
            catch(e: CancellationException){throw e} catch(e: Exception){if(epoch==searchEpoch)error=UserMessages.failure(e)}
            finally { if(epoch==searchEpoch)searching=false }
        }
    }
    fun openAlbum(album: Album) { albumJob?.cancel();val epoch=++albumEpoch;albumTracks=emptyList();albumLoading=true
        albumJob=viewModelScope.launch { try { val found=catalog.albumTracks(album);ensureActive();if(epoch==albumEpoch)albumTracks=found } catch(e: CancellationException){throw e} catch(e: Exception){if(epoch==albumEpoch)error=UserMessages.failure(e)} finally {if(epoch==albumEpoch)albumLoading=false} }
    }
    fun closeAlbum(){albumJob?.cancel();albumEpoch++;albumTracks=emptyList();albumLoading=false}
    fun saveServer(value: String) {
        runCatching {
            val url=value.trim().trimEnd('/').toHttpUrl()
            require(url.isHttps && url.username.isEmpty() && url.password.isEmpty() && url.query==null && url.fragment==null)
            serverEpoch++;connectionJob?.cancel();serverBusy=false;automaticServer=false;server=url.toString().trimEnd('/')
            prefs.edit().putString("server",server).putBoolean("automaticServer",false).apply()
            serverStatus="Custom connection saved."
        }.onFailure{serverStatus="Enter a complete secure address, starting with https://."}
    }
    fun useAutomaticServer() {
        if(serverBusy)return
        val epoch=++serverEpoch;automaticServer=true;serverBusy=true;error=null
        prefs.edit().putBoolean("automaticServer",true).apply()
        serverStatus="Connecting…"
        connectionJob=viewModelScope.launch {
            try {
                refreshDiscoveredServer(epoch,{serverEpoch},{automaticServer},{catalog.discover()}){found ->
                    server=found;lastDiscoveryMs=android.os.SystemClock.elapsedRealtime()
                    prefs.edit().putString("server",found).apply()
                    serverStatus="Automatic connection is ready."
                }
            } catch(e:CancellationException){throw e}
            catch(e:Exception){if(automaticServer && epoch==serverEpoch)serverStatus=UserMessages.failure(e,"Couldn’t connect. Check your internet and try again.")}
            finally{if(epoch==serverEpoch)serverBusy=false}
        }
    }
    fun saveQuality(value: String) { quality = value; prefs.edit().putString("quality", value).apply() }
    private suspend fun base(forceRefresh: Boolean=false): String {
        if(automaticServer && (forceRefresh || server.isBlank() || android.os.SystemClock.elapsedRealtime()-lastDiscoveryMs>45000)) {
            val epoch=serverEpoch
            try {
                refreshDiscoveredServer(epoch,{serverEpoch},{automaticServer},{catalog.discover()}) { found -> server=found;lastDiscoveryMs=android.os.SystemClock.elapsedRealtime();prefs.edit().putString("server",found).apply();serverStatus="Automatic connection is ready." }
            } catch(e: CancellationException){throw e}
            catch(e: Exception){
                if(server.isBlank())throw IllegalStateException("Couldn’t connect to music. Check your internet and try again.",e)
                if(automaticServer && epoch==serverEpoch)serverStatus="Using your saved connection."
            }
        }
        check(server.isNotBlank()){ "Connect to music in Settings, then try again." }
        return server.trimEnd('/').let{if(it.endsWith("/v1"))it else "$it/v1"}
    }
    private val resolvedDownloads=mutableMapOf<String,String>()
    private data class StreamSource(val url:String,val headers:Map<String,String>,val description:String,val seconds:Double?,val direct:Boolean,val host:String?=null,val token:String?=null)
    private suspend fun resolve(track:Track,forPlayback:Boolean=false,preferDirect:Boolean=false):Pair<String,Map<String,String>>{
        val requestedQuality=quality
        suspend fun backend():StreamSource=withTimeout(if(forPlayback)22000L else 45000L){
            val token=withTimeoutOrNull(4000){auth?.currentUser?.getIdToken(false)?.await()?.token}
            val headers=token?.let{mapOf("Authorization" to "Bearer $it")}.orEmpty()
            suspend fun request(address:String):StreamSource{
                // The resolve response itself establishes reachability; no extra health round trip.
                val metadata=JSONObject(catalog.text("$address/resolve/${track.playableID}?quality=$requestedQuality",headers,if(forPlayback)18 else 30))
                return StreamSource("$address/audio/${track.playableID}?quality=$requestedQuality",headers,audioDescription(metadata.optJSONObject("mediaInfo"),metadata.optString("quality",requestedQuality)),metadata.optDouble("duration",0.0).takeIf{it>0},false,address.toHttpUrl().host,token)
            }
            val first=base()
            try{request(first)}catch(e:CancellationException){throw e}catch(e:Exception){
                if(!automaticServer)throw e
                val refreshed=base(forceRefresh=true);if(refreshed==first)throw e;request(refreshed)
            }
        }
        suspend fun direct():StreamSource=withTimeout(if(forPlayback)25000L else 45000L){
            val stream=DirectMusic.resolve(track.playableID,requestedQuality)
            StreamSource(stream.audio.url,mapOf("User-Agent" to DirectMusic.USER_AGENT),audioDescription(stream.info(),requestedQuality),stream.duration,true)
        }
        val stream=if(preferDirect || android.os.SystemClock.elapsedRealtime()<backendRetryAfter)direct()
            else if(forPlayback)firstWorkingSource(4000,::backend,::direct)
            else try{backend()}catch(e:CancellationException){throw e}catch(e:Exception){direct()}
        currentCoroutineContext().ensureActive()
        if(stream.direct)backendRetryAfter=android.os.SystemClock.elapsedRealtime()+30000 else backendRetryAfter=0
        if(!stream.direct){PlaybackAuthorization.host=stream.host;PlaybackAuthorization.token=stream.token}
        if(forPlayback && current?.playableID==track.playableID){usingDirectPlayback=stream.direct;audioDetails=stream.description;stream.seconds?.let{duration=it}}
        if(!forPlayback)resolvedDownloads[track.playableID]=stream.description
        return stream.url to stream.headers
    }

    fun play(track: Track, following: List<Track>? = null, recovering: Boolean=false, resumeAt: Double=0.0, preferDirect: Boolean=false, fromHistory: Boolean=false) {
        if(!recovering && current?.playableID==track.playableID && (playJob?.isActive==true || loading))return
        if(!recovering && !fromHistory) {
            if(following!=null)previousTracks=following.takeWhile{it.id!=track.id}
            else current?.takeIf{it.playableID!=track.playableID}?.let{previousTracks=(previousTracks+it).takeLast(100)}
        }
        playJob?.cancel();startupWatchdog?.cancel();lyricJob?.cancel(); lyricEpoch++; controller?.stop();resolvingPlayback=true
        recoveringPlayback=recovering;audioDetails="Getting your song ready…";error=null;current = track; elapsed = resumeAt; duration = track.duration ?: 0.0; lyrics = emptyList(); loading = true
        if (following != null) queueEntries = following.dropWhile { it.id != track.id }.drop(1).map{QueueEntry(it)}
        playJob = viewModelScope.launch {
            try {
                val file = downloadedFile(track)
                usingLocalPlayback=file.isFile && file.length()>0 && !recovering
                val uri = if (usingLocalPlayback) { audioDetails=savedAudioDescription(prefs.getString("downloadQuality.${safeID(track.playableID)}",null));Uri.fromFile(file) } else Uri.parse(resolve(track,true,preferDirect).first)
                ensureActive()
                val c = controller ?: withTimeout(15000) { controllerFuture.awaitController() }.also { controller=it }
                c.setMediaItem(MediaItem.Builder().setMediaId(track.id).setUri(uri).setMediaMetadata(MediaMetadata.Builder()
                    .setTitle(track.title).setArtist(track.artist).setArtworkUri(notificationArtwork(track)).build()).build())
                resolvingPlayback=false
                c.prepare();if(resumeAt>0)c.seekTo((resumeAt*1000).toLong());c.play()
                if(!recovering && !usingLocalPlayback)startupWatchdog=viewModelScope.launch{
                    delay(18000)
                    if(current?.playableID==track.playableID && c.playWhenReady && c.playbackState==Player.STATE_BUFFERING && !c.isPlaying)
                        play(track,recovering=true,resumeAt=resumeAt,preferDirect=!usingDirectPlayback)
                }
                loadLyrics(track)
            } catch (e: CancellationException) { throw e } catch (e: Exception) { resolvingPlayback=false;error = UserMessages.failure(e); loading = false }
        }
    }
    private fun loadLyrics(track: Track,force: Boolean=false) {
        lyricJob?.cancel();val epoch=++lyricEpoch;lyricsLoading=true;lyricsError=null
        lyricJob=viewModelScope.launch {
            try { val found=fetchLyrics(track,force);ensureActive();if(epoch==lyricEpoch && current?.playableID==track.playableID)lyrics=found }
            catch(e: CancellationException){throw e} catch(e: Exception){if(epoch==lyricEpoch)lyricsError="Couldn’t load lyrics. Tap Retry."}
            finally { if(epoch==lyricEpoch)lyricsLoading=false }
        }
    }
    fun retryLyrics(){current?.let{loadLyrics(it,true)}}
    private fun lyricFile(track: Track)=File(getApplication<Application>().filesDir,"lyrics/${safeID(track.playableID)}.json")
    private suspend fun fetchLyrics(track: Track, force: Boolean=false): List<Lyric> {
        val key=track.playableID;val lock=lyricLocks.getOrPut(key){kotlinx.coroutines.sync.Mutex()};lock.lock()
        try {
            val cached=withContext(Dispatchers.IO){runCatching{Catalog.decodeLyrics(lyricFile(track).readText())}.getOrDefault(emptyList())}
            val manager=getApplication<Application>().getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            val online=manager.getNetworkCapabilities(manager.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)==true
            if(!online || (!force && cached.any{it.time!=null}))return cached
            if(!force && cached.isNotEmpty() && System.currentTimeMillis()-(lyricRefreshAt[key] ?: 0)<6*3600000L)return cached
            lyricRefreshAt[key]=System.currentTimeMillis()
            suspend fun attempt(block:suspend ()->List<Lyric>): List<Lyric> = try{block()}catch(e: CancellationException){throw e}catch(_: Exception){emptyList()}
            val backend=attempt{val token=auth?.currentUser?.getIdToken(false)?.await()?.token;catalog.backendLyrics(track,base(),token?.let{mapOf("Authorization" to "Bearer $it")}.orEmpty())}
            val found=if(backend.any{it.time!=null})backend else {
                val community=attempt{catalog.communityLyrics(track)}
                if(community.any{it.time!=null})community else {
                    val direct=attempt{catalog.lyrics(track)}
                    listOf(direct,backend,cached,community).firstOrNull{it.any{line->line.time!=null}} ?: listOf(backend,direct,cached,community).firstOrNull{it.isNotEmpty()}.orEmpty()
                }
            }
            if(found.isNotEmpty())withContext(Dispatchers.IO){runCatching{val file=lyricFile(track);file.parentFile!!.mkdirs();val temp=File(file.path+".tmp");temp.writeText(Catalog.encodeLyrics(found));check(temp.renameTo(file)){"Could not save lyrics"}}}
            return found
        } finally {lock.unlock()}
    }
    private fun artworkFile(track: Track)=File(getApplication<Application>().filesDir,"artwork/${safeID(track.artwork)}.jpg")
    private fun notificationArtwork(track: Track): Uri { val file=artworkFile(track);return if(file.exists())Uri.fromFile(file) else Uri.parse(Catalog.artworkForDisplay(track.artwork)) }
    private fun persistDownloads(){prefs.edit().putString("downloads",JSONArray(downloads.map{it.json()}).toString()).apply()}
    private fun validateAudio(file: File) {
        val extractor=android.media.MediaExtractor()
        try { extractor.setDataSource(file.path);val index=(0 until extractor.trackCount).firstOrNull{extractor.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/")==true} ?: error("Download did not contain playable audio");extractor.selectTrack(index);check(extractor.readSampleData(java.nio.ByteBuffer.allocate(1024*1024),0)>0){"Audio download is incomplete"} } finally {extractor.release()}
    }
    fun toggle() { if(resolvingPlayback)return;controller?.let { if (it.isPlaying) it.pause() else {if(it.playbackState==Player.STATE_IDLE)it.prepare();it.play()} } }
    fun seek(seconds: Double) { controller?.seekTo((seconds.coerceAtLeast(0.0) * 1000).toLong()) }
    fun next() { if (queue.isNotEmpty()) { val t = queue.first(); queueEntries = queueEntries.drop(1); play(t) } }
    fun previous() {
        if(elapsed>3 || previousTracks.isEmpty()){seek(0.0);return}
        val prior=previousTracks.last();previousTracks=previousTracks.dropLast(1)
        current?.let{queueEntries=listOf(QueueEntry(it))+queueEntries}
        play(prior,fromHistory=true)
    }
    fun playNext(track: Track) { queueEntries = listOf(QueueEntry(track)) + queueEntries }
    fun enqueue(track: Track) { queueEntries = queueEntries + QueueEntry(track) }
    fun removeQueue(index: Int) { queueEntries = queueEntries.filterIndexed { i, _ -> i != index } }
    fun moveQueue(index: Int, delta: Int) { val target = index + delta; if (target !in queue.indices) return; val list = queueEntries.toMutableList(); val item = list.removeAt(index); list.add(target, item); queueEntries = list }
    fun clearQueue() { queueEntries = emptyList() }
    private fun safeID(id: String) = MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).joinToString("") { "%02x".format(it) }
    fun downloadedFile(track: Track) = File(getApplication<Application>().filesDir, "downloads/${safeID(track.playableID)}.audio")
    private fun persistDownloadFailures(){prefs.edit().putString("downloadFailures",JSONObject(downloadFailures).toString()).apply()}
    fun retryFailedDownloads(tracks: List<Track>){tracks.filter{it.playableID in downloadFailures}.forEach{download(it)}}
    fun download(track: Track) {
        if(track.playableID in downloadingIDs || hasDownload(track))return
        downloadingIDs.add(track.playableID);downloading=downloading+track.playableID
        downloadFailures=downloadFailures-track.playableID;persistDownloadFailures()
        viewModelScope.launch {
            val destination=downloadedFile(track);val partial=File(destination.path+".part")
            var acquired=false
            try {
                downloadSlots.acquire();acquired=true
                retryAudioDownload { attempt ->
                    val (url,headers)=resolve(track,preferDirect=attempt==2)
                    withContext(Dispatchers.IO){
                        destination.parentFile!!.mkdirs();partial.delete()
                        val request=Request.Builder().url(url.replace("/audio/","/download/"));headers.forEach{(k,v)->request.header(k,v)}
                        catalog.http.newCall(request.build()).execute().use{response ->
                            if(!response.isSuccessful)throw DownloadHttpException(response.code)
                            check(response.header("Content-Type")?.contains("json")!=true){"Server did not return audio"}
                            val body=response.body ?: error("Empty download");val copied=body.byteStream().use{input -> partial.outputStream().use{input.copyTo(it)}}
                            check(body.contentLength()<0 || copied==body.contentLength()){ "Audio download was interrupted" }
                        }
                        validateAudio(partial)
                        check(partial.length()>0 && partial.renameTo(destination)){"Could not save download"}
                    }
                }
                downloads=downloads.filterNot{it.playableID==track.playableID}+track;persistDownloads()
                prefs.edit().putString("downloadQuality.${safeID(track.playableID)}","Offline · "+resolvedDownloads.remove(track.playableID).orEmpty()).apply()
                downloadFailures=downloadFailures-track.playableID;persistDownloadFailures()
                // Audio slots are released before optional lyrics/artwork caching.
                downloadSlots.release();acquired=false
                try{fetchLyrics(track)}catch(e: CancellationException){throw e}catch(_: Exception){}
                withContext(Dispatchers.IO){runCatching{val file=artworkFile(track);file.parentFile!!.mkdirs();catalog.http.newCall(Request.Builder().url(Catalog.artworkForDisplay(track.artwork)).build()).also{it.timeout().timeout(15,java.util.concurrent.TimeUnit.SECONDS)}.execute().use{response -> if(response.isSuccessful && response.header("Content-Type")?.startsWith("image/")==true){val temp=File(file.path+".tmp");temp.writeBytes(response.body!!.bytes());if(android.graphics.BitmapFactory.decodeFile(temp.path)!=null)temp.renameTo(file);temp.delete()}}}}
                if(current?.playableID==track.playableID)loadLyrics(track)
            }catch(e: CancellationException){throw e}catch(e: Exception){downloadFailures=downloadFailures+(track.playableID to UserMessages.failure(e,"Couldn’t download this song. Please try again."));persistDownloadFailures()}
            finally{if(acquired)downloadSlots.release();partial.delete();downloadingIDs.remove(track.playableID);downloading=downloading-track.playableID;resolvedDownloads.remove(track.playableID)}
        }
    }
    fun downloadAll(tracks: List<Track>){tracks.distinctBy{it.playableID}.forEach{download(it)}}
    fun addAlbumToPlaylist(album: Album, tracks: List<Track>){val id=createPlaylist(album.title,album.id) ?: return;tracks.distinctBy{it.playableID}.forEach{addToPlaylist(id,it)}}
    fun removeDownload(track: Track) { if (downloadedFile(track).delete()) { downloads = downloads.filterNot { it.id == track.id }; prefs.edit().putString("downloads", JSONArray(downloads.map { it.json() }).toString()).apply() } }
    fun createPlaylist(name: String, albumID: String?=null): String? { if (name.trim().isEmpty()) return null; val p = Playlist(UUID.randomUUID().toString(), name.trim(), emptyList(),albumID=albumID,ownerID=user?.uid); playlists = playlists + p; persistLibrary(); sync(p);return p.id }
    fun addToPlaylist(id: String, track: Track) { collaboration?.sharedPlaylists?.firstOrNull{it.id==id.removePrefix("cloud:") || (it.ownerID==user?.uid && it.sourceID==id)}?.let{shared -> collaboration?.editShared(shared){tracks -> if(tracks.any{it.playableID==track.playableID})tracks else tracks+track};return}; val p = playlists.firstOrNull { it.id == id } ?: return; if (p.tracks.any { it.id == track.id }) return; val updated = p.copy(tracks = p.tracks + track); playlists = playlists.map { if (it.id == id) updated else it }; persistLibrary(); sync(updated) }
    fun addTracksToPlaylist(id:String,tracks:List<Track>){
        collaboration?.sharedPlaylists?.firstOrNull{it.id==id.removePrefix("cloud:") || (it.ownerID==user?.uid && it.sourceID==id)}?.let{shared -> collaboration?.editShared(shared){current -> (current+tracks).distinctBy{it.playableID}};return}
        updatePlaylist(id){it.copy(tracks=(it.tracks+tracks).distinctBy{track->track.playableID})}
    }
    fun removeFromPlaylist(id: String, trackID: String) { collaboration?.sharedPlaylists?.firstOrNull{it.id==id.removePrefix("cloud:") || (it.ownerID==user?.uid && it.sourceID==id)}?.let{shared -> collaboration?.editShared(shared){tracks -> tracks.filterNot{it.id==trackID}};return}; val p = playlists.firstOrNull { it.id == id } ?: return; val updated = p.copy(tracks = p.tracks.filterNot { it.id == trackID }); playlists = playlists.map { if(it.id == id) updated else it }; persistLibrary(); sync(updated) }
    fun deletePlaylist(id: String) { collaboration?.sharedPlaylists?.firstOrNull{it.ownerID==user?.uid && (it.sourceID==id || "cloud:"+it.id==id)}?.let{shared -> collaboration?.deleteShared(shared){sharedSources=sharedSources-shared.sourceID;deletePersonalPlaylist(shared.sourceID)};return};deletePersonalPlaylist(id) }
    private fun deletePersonalPlaylist(id:String){ playlists = playlists.filterNot { it.id == id }; persistLibrary(); sync(null, id) }
    fun hasDownload(track: Track)=downloads.any{it.playableID==track.playableID} && downloadedFile(track).isFile
    fun renamePlaylist(id: String,name: String){if(name.isBlank())return;collaboration?.sharedPlaylists?.firstOrNull{it.ownerID==user?.uid && (it.sourceID==id || "cloud:"+it.id==id)}?.let{collaboration?.renameShared(it,name);return};updatePlaylist(id){it.copy(name=name.trim())}}
    private fun updatePlaylist(id: String,change:(Playlist)->Playlist){val p=playlists.firstOrNull{it.id==id} ?: return;val updated=change(p);playlists=playlists.map{if(it.id==id)updated else it};persistLibrary();sync(updated)}
    fun setPlaylistArtwork(id: String,uri: Uri){viewModelScope.launch{try{val app=getApplication<Application>();val file=withContext(Dispatchers.IO){val directory=File(app.filesDir,"playlist-artwork");directory.mkdirs();val target=File(directory,"${safeID(id)}-${UUID.randomUUID()}.jpg");app.contentResolver.openInputStream(uri)?.use{input -> val bitmap=android.graphics.BitmapFactory.decodeStream(input) ?: error("Choose an image");val scaled=android.graphics.Bitmap.createScaledBitmap(bitmap,minOf(bitmap.width,1000),maxOf(1,(bitmap.height.toDouble()*minOf(bitmap.width,1000)/bitmap.width).toInt()),true);target.outputStream().use{scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG,88,it)};target} ?: error("Couldn’t open image")};updatePlaylist(id){it.copy(artworkURL=Uri.fromFile(file).toString())}}catch(e: CancellationException){throw e}catch(e: Exception){error=UserMessages.failure(e)}}}
    private fun sync(playlist: Playlist?, id: String = playlist!!.id) {
        if (user == null || db == null) return
        val fields = mutableMapOf<String,Any>("playlistID" to id, "deleted" to (playlist == null), "updatedAt" to FieldValue.serverTimestamp())
        playlist?.let { val localCover=it.artworkURL?.takeIf{url->url.startsWith("file:")}?.let{url->runCatching{File(Uri.parse(url).path!!).readBytes()}.getOrNull()}
            val cloud=if(localCover!=null)it.copy(artworkURL=null) else it
            val bytes = cloud.json().toString().toByteArray(); if(bytes.size > 750000) { error = "This playlist is too large to sync. Try splitting it into smaller playlists."; return }; fields["payload"] = Blob.fromBytes(bytes)
            if(localCover!=null){val image=android.graphics.BitmapFactory.decodeByteArray(localCover,0,localCover.size);if(image!=null){val cover=boundedJpeg(image,128000);fields["cover"]=Blob.fromBytes(cover)}}
        }
        // Durable pending records survive offline edits and process restarts.
        val pendingValue = playlist?.json()?.toString() ?: "deleted"
        prefs.edit().putString("pending.$owner.$id", pendingValue).commit()
        val epoch = accountEpoch; val uid = owner
        db.collection("users").document(uid).collection("library").document(safeID(id)).set(fields, SetOptions.merge())
            .addOnSuccessListener { if(prefs.getString("pending.$uid.$id", null) == pendingValue) prefs.edit().remove("pending.$uid.$id").apply(); if(epoch == accountEpoch) cloudStatus = "Your library is saved" }
            .addOnFailureListener { if(epoch == accountEpoch) { cloudStatus = "Your library will sync when connected"; error = UserMessages.failure(it) } }
    }
    private fun bindCloud() {
        libraryListener?.remove(); val uid = user?.uid ?: run { cloudStatus = "Sign in to save playlists across devices"; return }
        val database = db ?: return; cloudStatus = "Syncing your library…"; val epoch = accountEpoch
        prefs.all.filterKeys { it.startsWith("pending.$uid.") }.forEach { (key, value) -> val id = key.removePrefix("pending.$uid."); if(value == "deleted") sync(null,id) else runCatching { sync(Playlist.from(JSONObject(value.toString()))) } }
        libraryListener = database.collection("users").document(uid).collection("library").addSnapshotListener { snapshot, failure ->
            if(epoch != accountEpoch) return@addSnapshotListener
            if(failure != null) { cloudStatus = "Couldn’t sync your library"; error = UserMessages.failure(failure); return@addSnapshotListener }
            if(snapshot != null) {
                var merged = playlists.associateBy { it.id }.toMutableMap()
                snapshot.documents.forEach { d -> val id = d.getString("playlistID") ?: return@forEach
                    if(prefs.contains("pending.$uid.$id")) return@forEach
                    if(d.getBoolean("deleted") == true) merged.remove(id)
                    else d.getBlob("payload")?.toBytes()?.let { bytes -> runCatching { Playlist.from(JSONObject(String(bytes))) }.onSuccess { var restored=it.copy(ownerID=it.ownerID ?: uid)
                        d.getBlob("cover")?.toBytes()?.let{cover -> val file=File(getApplication<Application>().filesDir,"playlist-artwork/${safeID(id)}-cloud.jpg");file.parentFile!!.mkdirs();file.writeBytes(cover);restored=restored.copy(artworkURL=Uri.fromFile(file).toString())}
                        merged[id] = restored } }
                }
                sharedSources.forEach{(id,item) -> val old=merged[id] ?: Playlist(id,item.name,emptyList(),ownerID=item.ownerID);merged[id]=old.copy(name=item.name,tracks=item.tracks,ownerID=item.ownerID)}
                playlists = merged.values.toList(); persistLibrary(); cloudStatus = if(snapshot.metadata.isFromCache) "Your saved library" else "Your library is saved"
            }
        }
    }
    private var signingOut=false
    fun signOut() {
        if(signingOut)return;signingOut=true
        viewModelScope.launch {
            try { user?.uid?.let { id -> withTimeoutOrNull(4000) { runCatching { PushRegistry.unregister(getApplication(),id) } } } }
            finally { auth?.signOut();signingOut=false }
        }
    }
    override fun onCleared() { libraryListener?.remove(); auth?.removeAuthStateListener(authListener); MediaController.releaseFuture(controllerFuture); super.onCleared() }
}

private suspend fun com.google.common.util.concurrent.ListenableFuture<MediaController>.awaitController(): MediaController = suspendCancellableCoroutine { continuation ->
    addListener({ try { val value=get();if(continuation.isActive)continuation.resumeWith(Result.success(value)) } catch(e: Exception){if(continuation.isActive)continuation.resumeWith(Result.failure(e))} },java.util.concurrent.Executor { it.run() })
}

fun audioDescription(info: JSONObject?, mode: String): String {
    val label=if(mode=="dataSaver")"Data saver" else "Best available"
    if(info==null)return "$label · quality details unavailable"
    val parts=mutableListOf(label)
    info.nullable("codec")?.let{codec -> parts+=when{codec.startsWith("mp4a") || codec.contains("aac",ignoreCase=true)->"AAC";codec.contains("opus",ignoreCase=true)->"Opus";else->"Audio"}}
    info.optDouble("bitrateKbps").takeIf{it.isFinite() && it>0}?.let{parts+="${it.toInt()} kbps"}
    info.optDouble("sampleRateHz").takeIf{it.isFinite() && it>0}?.let{parts+="${it/1000} kHz"}
    if(info.optInt("availableQualityCount")==1)parts+="Only one quality available"
    return parts.joinToString(" · ")
}

internal data class QueueEntry(val track: Track, val key: String = UUID.randomUUID().toString())

private fun savedAudioDescription(value:String?):String = value?.removePrefix("Direct fallback · ")
    ?.replace("Only one source quality","Only one quality available")
    ?.replace("format not reported","quality details unavailable")
    ?.replace("mp4a.40.2","AAC")
    ?.replace("Saved audio · quality unknown","Downloaded audio") ?: "Downloaded audio"
