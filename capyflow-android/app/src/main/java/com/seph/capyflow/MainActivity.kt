package com.seph.capyflow

import android.os.Bundle
import android.Manifest
import android.os.Build
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import coil.request.ImageRequest
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.zIndex
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.firebase.auth.GoogleAuthProvider
import kotlinx.coroutines.launch

val Violet = Color(0xFFDC95FF)
val Night = Color(0xFF06090E)
val Raised = Color(0xFF121B21)
val Glass = Color.White.copy(alpha = .075f)

class MainActivity : ComponentActivity() {
    private var model: CapyModel? = null
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
    private val signInLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        runCatching { GoogleSignIn.getSignedInAccountFromIntent(result.data).getResult(com.google.android.gms.common.api.ApiException::class.java) }
            .onSuccess { account -> val token = account.idToken
                if(token != null) model?.auth?.signInWithCredential(GoogleAuthProvider.getCredential(token,null))?.addOnFailureListener { model?.error = it.message }
                else model?.error = "Google sign-in did not return an identity token"
            }.onFailure { if((it as? com.google.android.gms.common.api.ApiException)?.statusCode != 12501) model?.error = "Google sign-in failed: ${it.message}" }
    }
    private fun signIn() {
        if(!BuildConfig.FIREBASE_CONFIGURED) { model?.error = "Account sign-in is not connected in this preview yet. You can still search, play music, download songs and use local playlists."; return }
        val res = resources.getIdentifier("default_web_client_id","string",packageName)
        if(res == 0) { model?.error = "Google sign-in is missing the web OAuth client ID. Enable Google authentication and download the updated Firebase configuration."; return }
        val options = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN).requestIdToken(getString(res)).requestEmail().build()
        signInLauncher.launch(GoogleSignIn.getClient(this,options).signInIntent)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); enableEdgeToEdge(statusBarStyle=SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),navigationBarStyle=SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        if(Build.VERSION.SDK_INT >= 33) permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        setContent {
            val vm: CapyModel = viewModel(); val social: SocialModel = viewModel(); model = vm
            LaunchedEffect(vm.user?.uid) { social.bind(vm.db,vm.user?.uid) }
            MaterialTheme(colorScheme = darkColorScheme(primary=Violet,secondary=Color(0xFFD78FEE),background=Night,surface=Raised,onPrimary=Night)) {
                CompositionLocalProvider(LocalContentColor provides Color.White) { CapyApp(vm,social,::signIn) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun CapyApp(vm: CapyModel,social: SocialModel,signIn: () -> Unit) {
    var tab by remember { mutableStateOf("Home") }
    var query by rememberSaveable { mutableStateOf("") }
    var albumsOnly by rememberSaveable { mutableStateOf(false) }
    var selectedAlbum by remember { mutableStateOf<Album?>(null) }
    var showPlayer by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showQueue by remember { mutableStateOf(false) }
    var showNewPlaylist by remember { mutableStateOf(false) }
    var selectedPlaylist by remember { mutableStateOf<String?>(null) }
    var addTrack by remember { mutableStateOf<Track?>(null) }
    var selectedProfile by remember { mutableStateOf<Profile?>(null) }
    var chatPeer by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxSize().background(Night)) {
        AmbientBackground()
        Scaffold(containerColor=Color.Transparent,bottomBar={
            Column(Modifier.navigationBarsPadding().padding(horizontal=16.dp,vertical=8.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                vm.current?.let { t -> MiniPlayer(t,vm,{showPlayer=true}) }
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(30.dp)).background(Glass).border(1.dp,Color.White.copy(alpha=.12f),RoundedCornerShape(30.dp)).padding(5.dp),horizontalArrangement=Arrangement.SpaceEvenly) {
                    listOf("Home" to Icons.Default.Home,"Search" to Icons.Default.Search,"Library" to Icons.Default.LibraryMusic,"Social" to Icons.Default.People).forEach { (label,icon) ->
                        Column(Modifier.weight(1f).clip(RoundedCornerShape(24.dp)).background(if(tab==label)Violet.copy(alpha=.16f) else Color.Transparent).clickable { tab=label; selectedPlaylist=null }.padding(vertical=10.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                            Icon(icon,label,tint=if(tab==label)Violet else Color.White.copy(alpha=.55f),modifier=Modifier.size(22.dp)); Text(label,color=if(tab==label)Violet else Color.White.copy(alpha=.6f),fontSize=11.sp,fontWeight=FontWeight.SemiBold)
                        }
                    }
                }
            }
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).widthIn(max=652.dp).align(Alignment.TopCenter).padding(horizontal=16.dp)) {
                Row(Modifier.fillMaxWidth().padding(top=12.dp,bottom=20.dp),verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("CAPYFLOW",color=Violet,fontSize=11.sp,fontWeight=FontWeight.Black,letterSpacing=3.sp); Text(if(selectedPlaylist!=null)vm.playlists.firstOrNull{it.id==selectedPlaylist}?.name ?: "Playlist" else tab,fontSize=32.sp,fontWeight=FontWeight.Bold) }
                    IconButton(onClick={showSettings=true},modifier=Modifier.clip(CircleShape).background(Glass)) { Icon(Icons.Default.AccountCircle,"Profile and settings",tint=Violet) }
                }
                when(tab) {
                    "Home" -> LazyColumn(verticalArrangement=Arrangement.spacedBy(20.dp)) {
                        item { Surface(shape=RoundedCornerShape(30.dp),color=Violet.copy(alpha=.10f)) { Column(Modifier.fillMaxWidth().padding(24.dp)) { Text("YOUR NEXT FAVORITE",color=Violet,fontSize=11.sp,letterSpacing=2.sp);Text("Find your flow.",fontSize=32.sp,fontWeight=FontWeight.Bold); Text("Your music. Your people. All in one place.",color=Color.White.copy(alpha=.65f),modifier=Modifier.padding(top=8.dp)); Button(onClick={tab="Search"},modifier=Modifier.padding(top=16.dp)) { Icon(Icons.Default.Search,null); Spacer(Modifier.width(8.dp)); Text("Explore music") } } } }
                        if(vm.downloads.isNotEmpty()) {
                            item { Section("Ready offline") }
                            items(vm.downloads.take(6),key={it.id}) { t -> TrackRow(t,{vm.play(t,vm.downloads)},vm,{addTrack=t}) }
                        }
                        if(vm.playlists.isNotEmpty()) {
                            item { Section("Your playlists") }
                            item { LazyRow(horizontalArrangement=Arrangement.spacedBy(12.dp)) { items(vm.playlists,key={it.id}) { p -> Column(Modifier.width(145.dp).clickable { selectedPlaylist=p.id; tab="Library" }) { Artwork(p.tracks.firstOrNull()?.artwork,145); Text(p.name,fontWeight=FontWeight.Bold,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.padding(top=10.dp)); Text("${p.tracks.size} songs",fontSize=12.sp,color=Color.White.copy(alpha=.6f)) } } } }
                        }
                        item { Spacer(Modifier.height(12.dp)) }
                    }
                    "Search" -> Column {
                        val album=selectedAlbum
                        if(album!=null) {
                            Row { TextButton(onClick={selectedAlbum=null;vm.closeAlbum()}){Icon(Icons.AutoMirrored.Filled.ArrowBack,null);Text("Albums")};Spacer(Modifier.weight(1f));TextButton(onClick={vm.openAlbum(album)}){Text("Refresh")} }
                            Row(Modifier.padding(vertical=12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(album.artwork,96);Column(Modifier.padding(start=16.dp)){Text(album.title,fontSize=23.sp,fontWeight=FontWeight.Bold);Text(album.artist,color=Violet);album.year?.let{Text(it,fontSize=12.sp)}}}
                            Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){TextButton(onClick={vm.addAlbumToPlaylist(album,vm.albumTracks)},enabled=vm.albumTracks.isNotEmpty()){Icon(Icons.Default.PlaylistAdd,null);Text("Add as playlist")};TextButton(onClick={vm.downloadAll(vm.albumTracks)},enabled=vm.albumTracks.isNotEmpty()){Icon(Icons.Default.Download,null);Text("Download all")}}
                            if(vm.albumLoading)LinearProgressIndicator(Modifier.fillMaxWidth())
                            LazyColumn { items(vm.albumTracks,key={it.id}) { t -> TrackRow(t,{vm.play(t,vm.albumTracks)},vm,{addTrack=t}) };if(!vm.albumLoading && vm.albumTracks.isEmpty())item{EmptyState("No tracks loaded","Tap Refresh to try again.",Icons.Default.Album)} }
                        } else {
                            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Glass).padding(4.dp)) { listOf(false to "Songs",true to "Albums").forEach { (mode,label) -> Text(label,color=if(albumsOnly==mode)Violet else Color.White.copy(alpha=.6f),fontWeight=FontWeight.SemiBold,modifier=Modifier.weight(1f).clip(RoundedCornerShape(20.dp)).background(if(albumsOnly==mode)Violet.copy(alpha=.14f) else Color.Transparent).clickable{albumsOnly=mode}.padding(12.dp)) } }
                            OutlinedTextField(query,{query=it},placeholder={Text(if(albumsOnly)"Search albums or artists" else "Search songs or artists")},singleLine=true,modifier=Modifier.fillMaxWidth().padding(top=12.dp),shape=RoundedCornerShape(24.dp),trailingIcon={IconButton(onClick={vm.search(query,albumsOnly)}){Icon(Icons.Default.Search,"Search")}})
                            LaunchedEffect(query,albumsOnly){kotlinx.coroutines.delay(400);vm.search(query,albumsOnly)}
                            if(vm.searching)LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical=12.dp))
                            LazyColumn(Modifier.padding(top=12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                if(query.isBlank())item{EmptyState("Find your favorites","Search by title or artist.",Icons.Default.Search)}
                                else if(!vm.searching && (if(albumsOnly)vm.albums.isEmpty() else vm.results.isEmpty()))item{EmptyState("No results found","Try another title or artist.",Icons.Default.Search)}
                                if(albumsOnly)items(vm.albums,key={it.id}){a -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Glass).clickable{selectedAlbum=a;vm.openAlbum(a)}.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(a.artwork,72);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(a.title,fontWeight=FontWeight.Bold);Text(a.artist,color=Violet,fontSize=13.sp);a.year?.let{Text(it,fontSize=12.sp)}};Icon(Icons.Default.ChevronRight,null)} }
                                else items(vm.results,key={it.id}){t -> TrackRow(t,{vm.play(t,vm.results)},vm,{addTrack=t})}
                            }
                        }
                    }
                    "Library" -> {
                        val playlist = vm.playlists.firstOrNull { it.id == selectedPlaylist }
                        if(playlist != null) Column {
                            Row(verticalAlignment=Alignment.CenterVertically) { TextButton(onClick={selectedPlaylist=null}) {Icon(Icons.AutoMirrored.Filled.ArrowBack,null); Text("Library")}; Spacer(Modifier.weight(1f)); IconButton(onClick={vm.deletePlaylist(playlist.id);selectedPlaylist=null}) {Icon(Icons.Default.Delete,"Delete playlist")} }
                            Row(verticalAlignment=Alignment.CenterVertically){Text("${playlist.tracks.size} songs",color=Color.White.copy(alpha=.6f),modifier=Modifier.weight(1f));TextButton(onClick={vm.downloadAll(playlist.tracks)},enabled=playlist.tracks.isNotEmpty()){Icon(Icons.Default.Download,null);Text("Download all")}}
                            LazyColumn(verticalArrangement=Arrangement.spacedBy(8.dp)) { items(playlist.tracks,key={it.id}) {t -> TrackRow(t,{vm.play(t,playlist.tracks)},vm,{addTrack=t},remove={vm.removeFromPlaylist(playlist.id,t.id)})} }
                        } else LazyColumn(verticalArrangement=Arrangement.spacedBy(12.dp)) {
                            item { Row(verticalAlignment=Alignment.CenterVertically) { Text(vm.cloudStatus,color=Color.White.copy(alpha=.6f),fontSize=12.sp,modifier=Modifier.weight(1f)); TextButton(onClick={showNewPlaylist=true}) {Icon(Icons.Default.Add,null); Text("Create") } } }
                            items(vm.playlists,key={it.id}) { p -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Glass).clickable{selectedPlaylist=p.id}.padding(14.dp),verticalAlignment=Alignment.CenterVertically) {Artwork(p.tracks.firstOrNull()?.artwork,56); Column(Modifier.padding(start=12.dp)) {Text(p.name,fontWeight=FontWeight.Bold);Text("${p.tracks.size} songs",fontSize=12.sp,color=Color.White.copy(alpha=.6f))} } }
                            item { Section("Downloads · ${vm.downloads.size}") }
                            if(vm.downloads.isEmpty()) item { EmptyState("Your music, anywhere","Download a song from its menu to listen offline.",Icons.Default.Download) }
                            items(vm.downloads,key={"download-${it.id}"}) { t -> TrackRow(t,{vm.play(t,vm.downloads)},vm,{addTrack=t},remove={vm.removeDownload(t)}) }
                        }
                    }
                    "Social" -> {
                        if(vm.user == null) Column { EmptyState("Listen together","Sign in with the same Google account you use on iOS.",Icons.Default.People); Button(onClick=signIn,modifier=Modifier.fillMaxWidth()) {Text("Continue with Google")} }
                        else SocialScreen(social,vm,onProfile={selectedProfile=it},onChat={social.openChat(it);chatPeer=it})
                    }
                }
            }
        }
        AnimatedVisibility(showPlayer,enter=slideInVertically(tween(320),initialOffsetY={it})+fadeIn(tween(180)),exit=slideOutVertically(tween(280),targetOffsetY={it})+fadeOut(tween(240))) {
            BackHandler(enabled=showPlayer){showPlayer=false}
            PlayerScreen(vm,{showPlayer=false},{showQueue=true},{vm.current?.let{addTrack=it}})
        }
    }
    if(showQueue) ModalBottomSheet(onDismissRequest={showQueue=false},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night) { QueueSheet(vm) }
    if(showSettings) ModalBottomSheet(onDismissRequest={showSettings=false},containerColor=Night) { Settings(vm,signIn) }
    if(showNewPlaylist) { var name by remember {mutableStateOf("")}; AlertDialog(onDismissRequest={showNewPlaylist=false},title={Text("New playlist")},text={OutlinedTextField(name,{name=it},label={Text("Playlist name")})},confirmButton={TextButton(onClick={val id=vm.createPlaylist(name);if(id!=null)addTrack?.let{vm.addToPlaylist(id,it)};addTrack=null;showNewPlaylist=false},enabled=name.isNotBlank()) {Text("Create")}},dismissButton={TextButton(onClick={showNewPlaylist=false}) {Text("Cancel")}}) }
    addTrack?.takeUnless{showNewPlaylist}?.let { t -> ModalBottomSheet(onDismissRequest={addTrack=null},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night) {
        Column(Modifier.fillMaxWidth().padding(20.dp).navigationBarsPadding()) {Section("Add to playlist");Row(Modifier.padding(vertical=12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(t.artwork,48);Column(Modifier.padding(start=12.dp)){Text(t.title,maxLines=1,overflow=TextOverflow.Ellipsis);Text(t.artist,color=Violet,fontSize=12.sp)}}
            TextButton(onClick={showNewPlaylist=true},modifier=Modifier.fillMaxWidth()){Icon(Icons.Default.Add,null);Text("Create a new playlist")}
            LazyColumn(Modifier.heightIn(max=420.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){items(vm.playlists,key={it.id}){p -> val added=p.tracks.any{it.playableID==t.playableID};Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Glass).clickable(enabled=!added){vm.addToPlaylist(p.id,t);addTrack=null}.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(p.tracks.firstOrNull()?.artwork,56);Column(Modifier.weight(1f).padding(start=12.dp)){Text(p.name,fontWeight=FontWeight.Bold);Text(if(added)"Already added" else "${p.tracks.size} songs",fontSize=12.sp,color=Color.White.copy(alpha=.6f))};Icon(if(added)Icons.Default.CheckCircle else Icons.Default.Add,null,tint=Violet)} } }
        }
    } }
    selectedProfile?.let { p -> ModalBottomSheet(onDismissRequest={selectedProfile=null},containerColor=Night) {Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding(),horizontalAlignment=Alignment.CenterHorizontally) {Artwork(p.avatar,88);Text(p.displayName,fontSize=26.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(top=12.dp));Text("@${p.username}",color=Violet); if(p.bio.isNotBlank())Text(p.bio,modifier=Modifier.padding(vertical=16.dp));if(p.id!=vm.user?.uid)Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){Button(onClick={social.follow(p,p.id !in social.following)}){Text(if(p.id in social.following)"Unfollow" else "Follow")};OutlinedButton(onClick={social.openChat(p.id);chatPeer=p.id;selectedProfile=null}){Text("Message")}}} } }
    chatPeer?.let { id -> ModalBottomSheet(onDismissRequest={social.closeChat();chatPeer=null},containerColor=Night,modifier=Modifier.fillMaxHeight(),dragHandle=null) {ChatScreen(id,vm,social){social.closeChat();chatPeer=null}} }
    val error = vm.error ?: social.error
    if(error != null) AlertDialog(onDismissRequest={vm.error=null;social.error=null},title={Text("CapyFlow")},text={Text(error)},confirmButton={TextButton(onClick={vm.error=null;social.error=null}) {Text("OK")}})
}

@Composable fun Section(title: String) {Text(title,fontSize=20.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(vertical=8.dp))}
@Composable fun AmbientBackground(){ Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Violet.copy(alpha=.12f),Color.Transparent),center=Offset(900f,0f),radius=1500f))) }
@Composable fun Artwork(url: String?,size: Int) {
    val context=LocalContext.current
    val data=remember(url,size){url?.let{val hash=java.security.MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString(""){b -> "%02x".format(b)};val file=java.io.File(context.filesDir,"artwork/$hash.jpg");if(file.exists())file else Catalog.artworkForDisplay(it,if(size>100)1200 else 320)}}
    Box(Modifier.size(size.dp).clip(RoundedCornerShape(if(size>100)30.dp else 14.dp)).background(Raised),contentAlignment=Alignment.Center){Icon(Icons.Default.MusicNote,null,tint=Violet,modifier=Modifier.size((size/3).dp));if(data!=null)AsyncImage(ImageRequest.Builder(context).data(data).crossfade(true).build(),null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)}
}
@Composable fun EmptyState(title: String,subtitle: String,icon: ImageVector) {Column(Modifier.fillMaxWidth().padding(vertical=32.dp),horizontalAlignment=Alignment.CenterHorizontally) {Icon(icon,null,tint=Violet,modifier=Modifier.size(44.dp));Text(title,fontSize=20.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(top=16.dp));Text(subtitle,color=Color.White.copy(alpha=.6f),modifier=Modifier.padding(top=8.dp))} }
@Composable fun TrackRow(track: Track,onPlay: ()->Unit,vm: CapyModel,onAdd: ()->Unit,remove: (() -> Unit)?=null) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(if(vm.current?.id==track.id)Violet.copy(alpha=.10f) else Color.Transparent).clickable(onClick=onPlay).padding(8.dp),verticalAlignment=Alignment.CenterVertically) {
        Artwork(track.artwork,56);Column(Modifier.weight(1f).padding(horizontal=12.dp)) {Text(track.title,maxLines=2,overflow=TextOverflow.Ellipsis,fontWeight=FontWeight.SemiBold,color=if(vm.current?.id==track.id)Violet else Color.White);Text(track.artist,maxLines=1,overflow=TextOverflow.Ellipsis,fontSize=12.sp,color=Color.White.copy(alpha=.6f))}
        if(track.id in vm.downloading)CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp)
        Box {IconButton(onClick={menu=true}) {Icon(Icons.Default.MoreVert,"Song options")};DropdownMenu(menu,{menu=false}) {DropdownMenuItem(text={Text("Play next / add to queue")},onClick={vm.enqueue(track);menu=false});DropdownMenuItem(text={Text("Add to playlist")},onClick={onAdd();menu=false});DropdownMenuItem(text={Text(if(vm.downloads.any{it.id==track.id})"Downloaded" else "Download")},onClick={vm.download(track);menu=false});if(remove!=null)DropdownMenuItem(text={Text("Remove")},onClick={remove();menu=false})} }
    }
}
@Composable fun MiniPlayer(track: Track,vm: CapyModel,onOpen: ()->Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Raised.copy(alpha=.96f)).border(1.dp,Color.White.copy(alpha=.13f),RoundedCornerShape(24.dp)).clickable(onClick=onOpen).padding(10.dp),verticalAlignment=Alignment.CenterVertically) {
        Artwork(track.artwork,46);Column(Modifier.weight(1f).padding(horizontal=10.dp)) {Text(track.title,maxLines=1,overflow=TextOverflow.Ellipsis,fontWeight=FontWeight.SemiBold,fontSize=14.sp);Text(track.artist,maxLines=1,overflow=TextOverflow.Ellipsis,color=Violet,fontSize=12.sp)}
        if(vm.loading)CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp) else IconButton(onClick={vm.toggle()}) {Icon(if(vm.playing)Icons.Default.Pause else Icons.Default.PlayArrow,"Play or pause",tint=Violet)}
        IconButton(onClick={vm.next()},enabled=vm.queue.isNotEmpty()) {Icon(Icons.Default.SkipNext,"Next song")}
    }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun PlayerScreen(vm: CapyModel,onClose: ()->Unit,onQueue: ()->Unit,onAdd: ()->Unit) {
    var showLyrics by rememberSaveable {mutableStateOf(false)}
    var scrub by remember {mutableFloatStateOf(0f)};var scrubbing by remember {mutableStateOf(false)};val track=vm.current
    LaunchedEffect(vm.elapsed){if(!scrubbing)scrub=vm.elapsed.toFloat()}
    Box(Modifier.fillMaxSize().background(Night)) { AmbientBackground()
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            val artSize=minOf(300f,maxWidth.value-48,maxHeight.value*.28f).coerceAtLeast(1f).toInt()
            Column(Modifier.fillMaxSize().widthIn(max=620.dp).align(Alignment.TopCenter).verticalScroll(rememberScrollState()).padding(horizontal=24.dp,vertical=8.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){IconButton(onClick=onClose){Icon(Icons.Default.KeyboardArrowDown,"Close player")};Column(Modifier.weight(1f),horizontalAlignment=Alignment.CenterHorizontally){Text("NOW PLAYING",fontSize=11.sp,letterSpacing=2.sp,fontWeight=FontWeight.Bold);Text("CapyFlow",fontSize=12.sp,color=Violet)};IconButton(onClick=onAdd){Icon(Icons.Default.PlaylistAdd,"Add to playlist")}}
                Spacer(Modifier.height(12.dp));Artwork(track?.artwork,artSize)
                Column(Modifier.fillMaxWidth().padding(top=16.dp,bottom=4.dp)){Text(track?.title ?: "CapyFlow",fontSize=26.sp,fontWeight=FontWeight.Bold,maxLines=2,overflow=TextOverflow.Ellipsis);Text(track?.artist.orEmpty(),fontSize=16.sp,color=Color.White.copy(alpha=.66f),maxLines=1,overflow=TextOverflow.Ellipsis)}
                Slider(value=scrub.coerceIn(0f,maxOf(vm.duration.toFloat(),1f)),onValueChange={scrubbing=true;scrub=it},onValueChangeFinished={vm.seek(scrub.toDouble());scrubbing=false},valueRange=0f..maxOf(vm.duration.toFloat(),1f),thumb={Box(Modifier.size(12.dp).background(Violet,CircleShape))},track={state -> SliderDefaults.Track(state,modifier=Modifier.height(4.dp),colors=SliderDefaults.colors(activeTrackColor=Violet,inactiveTrackColor=Color.White.copy(alpha=.14f)),drawStopIndicator=null,thumbTrackGapSize=0.dp)})
                Row(Modifier.fillMaxWidth()){Text(clock(if(scrubbing)scrub.toDouble() else vm.elapsed),fontSize=12.sp,color=Color.White.copy(alpha=.5f));Spacer(Modifier.weight(1f));Text("−"+clock((vm.duration-(if(scrubbing)scrub.toDouble() else vm.elapsed)).coerceAtLeast(0.0)),fontSize=12.sp,color=Color.White.copy(alpha=.5f))}
                Row(Modifier.padding(vertical=14.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(32.dp)){IconButton(onClick={vm.previous()},modifier=Modifier.size(52.dp)){Icon(Icons.Default.SkipPrevious,"Restart song",modifier=Modifier.size(32.dp))};FilledIconButton(onClick={vm.toggle()},modifier=Modifier.size(70.dp)){if(vm.loading)CircularProgressIndicator(Modifier.size(28.dp),color=Night) else Icon(if(vm.playing)Icons.Default.Pause else Icons.Default.PlayArrow,"Play or pause",modifier=Modifier.size(36.dp))};IconButton(onClick={vm.next()},enabled=vm.queue.isNotEmpty(),modifier=Modifier.size(52.dp)){Icon(Icons.Default.SkipNext,"Next song",modifier=Modifier.size(32.dp))}}
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                    PlayerAction("Lyrics",Icons.Default.FormatQuote,showLyrics,Modifier.weight(1f)){showLyrics=!showLyrics}
                    val saved=track!=null && vm.downloads.any{it.playableID==track.playableID};val downloading=track?.id in vm.downloading
                    PlayerAction(if(downloading)"Saving…" else if(saved)"Saved" else "Save",if(saved)Icons.Default.CheckCircle else Icons.Default.Download,saved,Modifier.weight(1f)){track?.let{vm.download(it)}}
                    PlayerAction("Queue",Icons.AutoMirrored.Filled.QueueMusic,false,Modifier.weight(1f),onQueue)
                }
                Text(vm.audioDetails,fontSize=10.sp,color=Color.White.copy(alpha=.45f),modifier=Modifier.padding(top=8.dp))
                AnimatedVisibility(showLyrics,enter=expandVertically(tween(250))+fadeIn(),exit=shrinkVertically(tween(220))+fadeOut()) { LyricsPanel(vm) }
            }
        }
    }
}
@Composable fun PlayerAction(label: String,icon: ImageVector,selected: Boolean,modifier: Modifier=Modifier,onClick:()->Unit){Column(modifier.clip(RoundedCornerShape(20.dp)).background(if(selected)Violet.copy(alpha=.15f) else Glass).border(1.dp,Color.White.copy(alpha=.09f),RoundedCornerShape(20.dp)).clickable(onClick=onClick).padding(vertical=12.dp),horizontalAlignment=Alignment.CenterHorizontally){Icon(icon,null,tint=if(selected)Violet else Color.White,modifier=Modifier.size(22.dp));Text(label,fontSize=11.sp,modifier=Modifier.padding(top=4.dp))}}
@Composable fun LyricsPanel(vm: CapyModel) {
    val state=rememberLazyListState();val density=LocalDensity.current;val followOffset=with(density){36.dp.roundToPx()};val lines=vm.lyrics;val active=lines.indexOfLast{it.time!=null && it.time<=vm.elapsed};val synced=lines.any{it.time!=null}
    LaunchedEffect(vm.current?.playableID,lines,active){if(synced && lines.isNotEmpty())state.animateScrollToItem(maxOf(0,active),-followOffset)}
    Column(Modifier.fillMaxWidth().padding(top=12.dp).clip(RoundedCornerShape(24.dp)).background(Glass).padding(horizontal=18.dp,vertical=12.dp)) {
        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Text(if(synced)"LIVE LYRICS" else "LYRICS",fontSize=10.sp,letterSpacing=2.sp,color=Violet,modifier=Modifier.weight(1f));if(!synced && lines.isNotEmpty())Text("Timing unavailable",fontSize=10.sp,color=Color.White.copy(alpha=.5f))}
        Box(Modifier.fillMaxWidth().height(152.dp),contentAlignment=Alignment.CenterStart) {
            if(vm.lyricsLoading)CircularProgressIndicator(Modifier.size(24.dp))
            else if(vm.lyricsError!=null)Column{Text(vm.lyricsError.orEmpty(),fontSize=13.sp);TextButton(onClick={vm.retryLyrics()}){Text("Retry")}}
            else if(lines.isEmpty())Text("Lyrics aren’t available for this track yet.",color=Color.White.copy(alpha=.6f),fontSize=13.sp)
            else LazyColumn(state=state,modifier=Modifier.fillMaxSize(),contentPadding=PaddingValues(top=12.dp,bottom=100.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                items(lines.size){i -> val line=lines[i];val color by animateColorAsState(if(i==active)Violet else Color.White.copy(alpha=if(synced && i<active).3f else .65f),tween(250),label="Lyric highlight");Text(line.text,fontSize=21.sp,fontWeight=FontWeight.SemiBold,color=color,modifier=Modifier.fillMaxWidth().clickable(enabled=line.time!=null){line.time?.let{vm.seek(it)}})}
            }
        }
    }
}
@Composable fun QueueSheet(vm: CapyModel) {
    val listState=rememberLazyListState()
    Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal=20.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Section("Up next");Text("Drag the handle to reorder · swipe left to remove",fontSize=11.sp,color=Color.White.copy(alpha=.5f))};TextButton(onClick={vm.clearQueue()}){Text("Clear")}}
        vm.current?.let{track -> Row(Modifier.fillMaxWidth().padding(vertical=16.dp),verticalAlignment=Alignment.CenterVertically){Artwork(track.artwork,48);Column(Modifier.padding(start=12.dp)){Text("NOW PLAYING",fontSize=10.sp,color=Violet,letterSpacing=1.sp);Text(track.title,maxLines=1,overflow=TextOverflow.Ellipsis)}}}
        LazyColumn(Modifier.fillMaxWidth().heightIn(max=480.dp),state=listState,verticalArrangement=Arrangement.spacedBy(8.dp),contentPadding=PaddingValues(bottom=20.dp)) {
            items(vm.queue.size,key={i -> vm.queue[i].id+":"+vm.queue.take(i).count{it.id==vm.queue[i].id}}){index -> QueueItem(vm,index,listState,Modifier.animateItem())}
            if(vm.queue.isEmpty())item{EmptyState("You’re all caught up","Add a song to your queue.",Icons.AutoMirrored.Filled.QueueMusic)}
        }
    }
}
@Composable fun QueueItem(vm: CapyModel,index: Int,listState: androidx.compose.foundation.lazy.LazyListState,modifier: Modifier=Modifier) {
    val track=vm.queue.getOrNull(index) ?: return
    val scope=rememberCoroutineScope()
    val density=LocalDensity.current;val reveal=with(density){80.dp.toPx()};val step=with(density){80.dp.toPx()}
    var swipe by remember(track.playableID){mutableFloatStateOf(0f)};var drag by remember(track.playableID){mutableFloatStateOf(0f)};var movingIndex by remember(track.playableID){mutableIntStateOf(index)}
    val latestIndex by rememberUpdatedState(index)
    val animatedSwipe by animateFloatAsState(swipe,tween(160),label="Queue swipe")
    Box(modifier.zIndex(if(drag!=0f)1f else 0f).offset{IntOffset(0,drag.toInt())}.fillMaxWidth().height(72.dp).clip(RoundedCornerShape(20.dp)).background(Color(0xFF652D42))) {
        TextButton(onClick={vm.removeQueue(latestIndex)},modifier=Modifier.align(Alignment.CenterEnd).width(80.dp)){Text("Remove",color=Color.White,fontSize=12.sp)}
        Row(Modifier.fillMaxSize().offset{IntOffset(animatedSwipe.toInt(),0)}.background(Raised).pointerInput(track.playableID){detectHorizontalDragGestures(onDragEnd={swipe=if(swipe < -reveal/2)-reveal else 0f},onDragCancel={swipe=0f}){change,amount -> change.consume();swipe=(swipe+amount).coerceIn(-reveal,0f)}}.padding(horizontal=10.dp),verticalAlignment=Alignment.CenterVertically) {
            Artwork(track.artwork,48);Column(Modifier.weight(1f).padding(horizontal=12.dp).clickable{val i=latestIndex;vm.removeQueue(i);vm.play(track)}){Text(track.title,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis);Text(track.artist,fontSize=12.sp,color=Color.White.copy(alpha=.55f),maxLines=1,overflow=TextOverflow.Ellipsis)}
            Icon(Icons.Default.DragHandle,"Drag to reorder",tint=Color.White.copy(alpha=.5f),modifier=Modifier.size(42.dp).pointerInput(track.playableID){detectDragGestures(onDragStart={movingIndex=latestIndex;drag=0f;swipe=0f},onDragEnd={drag=0f},onDragCancel={drag=0f}){change,amount -> change.consume();drag+=amount.y;if(kotlin.math.abs(drag)>=step*.65f){val delta=if(drag>0)1 else -1;val target=movingIndex+delta;if(target in vm.queue.indices){vm.moveQueue(movingIndex,delta);movingIndex=target;drag-=delta*step;val visible=listState.layoutInfo.visibleItemsInfo;if(visible.isNotEmpty() && (target>=visible.last().index || target<=visible.first().index))scope.launch{listState.animateScrollToItem(maxOf(0,target-1))}}}}})
        }
    }
}
fun clock(seconds: Double): String {val value=if(seconds.isFinite())seconds.toInt().coerceAtLeast(0) else 0;return "%d:%02d".format(value/60,value%60)}
@Composable fun Settings(vm: CapyModel,signIn: ()->Unit) {
    var server by remember(vm.server){mutableStateOf(vm.server)}
    Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding().verticalScroll(rememberScrollState())) {
        Section("Your CapyFlow")
        vm.user?.let{Text(it.displayName ?: "Signed in",fontSize=22.sp,fontWeight=FontWeight.Bold);Text(it.email ?: "",color=Violet);TextButton(onClick={vm.signOut()}){Text("Sign out")}} ?: Button(onClick=signIn,modifier=Modifier.fillMaxWidth()){Text("Continue with Google")}
        Section("Streaming server");Text(if(vm.automaticServer)"Automatic · follows your backend after restarts" else "Manual · uses the address you saved",color=Color.White.copy(alpha=.6f),fontSize=13.sp)
        OutlinedTextField(server,{server=it},label={Text("HTTPS server address")},modifier=Modifier.fillMaxWidth().padding(top=12.dp),singleLine=true,shape=RoundedCornerShape(18.dp));Row {TextButton(onClick={vm.saveServer(server)}){Text("Save manual address")};TextButton(onClick={vm.useAutomaticServer()}){Text("Use automatic")}}
        if(vm.serverStatus.isNotBlank())Text(vm.serverStatus,color=Violet,fontSize=12.sp)
        Section("Audio quality");Text("Applies to the next stream or download. Saved tracks keep their downloaded quality.",fontSize=12.sp,color=Color.White.copy(alpha=.6f));Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){listOf("automatic","dataSaver").forEach{q -> FilterChip(vm.quality==q,{vm.saveQuality(q)},label={Text(if(q=="dataSaver")"Data saver" else "Best available")})}}
        Text("CapyFlow Android ${BuildConfig.VERSION_NAME}",color=Color.White.copy(alpha=.4f),fontSize=12.sp,modifier=Modifier.padding(top=24.dp))
    }
}
@Composable fun SocialScreen(social: SocialModel,vm: CapyModel,onProfile:(Profile)->Unit,onChat:(String)->Unit) {
    var query by remember {mutableStateOf("")};val scope=rememberCoroutineScope()
    Column {
        OutlinedTextField(query,{query=it},label={Text("Find people by username")},singleLine=true,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp),trailingIcon={IconButton(onClick={social.findPeople(query)}){Icon(Icons.Default.Search,"Find people")}})
        if(social.searching)LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical=8.dp))
        LazyColumn(verticalArrangement=Arrangement.spacedBy(10.dp)) {
            items(social.profiles,key={it.id}) {p -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Glass).clickable{onProfile(p)}.padding(14.dp),verticalAlignment=Alignment.CenterVertically){Artwork(p.avatar,48);Column(Modifier.weight(1f).padding(start=12.dp)){Text(p.displayName,fontWeight=FontWeight.Bold);Text("@${p.username}",fontSize=12.sp,color=Violet);if(p.bio.isNotBlank())Text(p.bio,fontSize=12.sp,maxLines=2,overflow=TextOverflow.Ellipsis)};if(p.id!=vm.user?.uid)IconButton(onClick={social.follow(p,p.id !in social.following)}){Icon(if(p.id in social.following)Icons.Default.PersonRemove else Icons.Default.PersonAdd,"Follow or unfollow")}} }
            item {Section("Messages")}
            if(social.inbox.isEmpty())item{Text("Follow someone to start a conversation from their profile.",color=Color.White.copy(alpha=.6f))}
            items(social.inbox,key={it.id}) {c -> var profile by remember(c.peer){mutableStateOf<Profile?>(null)};LaunchedEffect(c.peer){runCatching{social.profile(c.peer)}.onSuccess{profile=it}};Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Glass).clickable{onChat(c.peer)}.padding(16.dp),verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Text(profile?.displayName ?: "CapyFlow listener",fontWeight=FontWeight.Bold);Text(c.text,maxLines=1,overflow=TextOverflow.Ellipsis,fontSize=13.sp,color=Color.White.copy(alpha=.6f))};if(c.unread)Box(Modifier.size(8.dp).background(Violet,CircleShape))} }
        }
    }
}
@Composable fun ChatScreen(peer: String,vm: CapyModel,social: SocialModel,onClose:()->Unit) {
    var draft by remember(peer){mutableStateOf("")};var profile by remember(peer){mutableStateOf<Profile?>(null)}
    LaunchedEffect(peer){runCatching{social.profile(peer)}.onSuccess{profile=it}}
    Column(Modifier.fillMaxSize().imePadding().navigationBarsPadding().padding(16.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically){IconButton(onClick=onClose){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Text(profile?.displayName ?: "Messages",fontSize=22.sp,fontWeight=FontWeight.Bold)}
        LazyColumn(Modifier.weight(1f).fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(10.dp),reverseLayout=true){items(social.messages.reversed(),key={it.id}){m -> Row(Modifier.fillMaxWidth(),horizontalArrangement=if(m.sender==vm.user?.uid)Arrangement.End else Arrangement.Start){Column(Modifier.widthIn(max=280.dp).clip(RoundedCornerShape(20.dp)).background(if(m.sender==vm.user?.uid)Violet.copy(alpha=.22f) else Glass).padding(14.dp)){Text(m.text);if(m.pending)Text("Sending…",fontSize=10.sp,color=Color.White.copy(alpha=.5f))}}}}
        Row(Modifier.padding(top=12.dp),verticalAlignment=Alignment.CenterVertically){OutlinedTextField(draft,{if(it.length<=4000)draft=it},placeholder={Text("Message")},modifier=Modifier.weight(1f),shape=RoundedCornerShape(24.dp),maxLines=4);IconButton(onClick={val submitted=draft;social.send(submitted){if(draft==submitted)draft=""}},enabled=draft.isNotBlank()&&!social.sending){Icon(Icons.AutoMirrored.Filled.Send,"Send message",tint=Violet)}}
    }
}
