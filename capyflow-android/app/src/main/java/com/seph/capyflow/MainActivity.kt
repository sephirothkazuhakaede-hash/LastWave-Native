package com.seph.capyflow

import android.os.Bundle
import android.Manifest
import android.os.Build
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.foundation.lazy.itemsIndexed
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
    private val messageIntent = mutableStateOf<String?>(null)
    override fun onNewIntent(intent: android.content.Intent) {super.onNewIntent(intent);setIntent(intent);messageIntent.value=intent.getStringExtra("chatPeer")}
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> if(granted && BuildConfig.FIREBASE_CONFIGURED)PushRegistry.bind(this,com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid) }
    private val signInLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        runCatching { GoogleSignIn.getSignedInAccountFromIntent(result.data).getResult(com.google.android.gms.common.api.ApiException::class.java) }
            .onSuccess { account -> val token = account.idToken
                if(token != null) model?.auth?.signInWithCredential(GoogleAuthProvider.getCredential(token,null))?.addOnFailureListener { model?.error = UserMessages.failure(it,"Couldn’t sign in. Please try again.") }
                else model?.error = "Couldn’t sign in. Please try again."
            }.onFailure { if((it as? com.google.android.gms.common.api.ApiException)?.statusCode != 12501) model?.error = "Couldn’t sign in. Please try again." }
    }
    override fun onResume(){super.onResume();androidx.lifecycle.ViewModelProvider(this)[AppUpdater::class.java].checkAutomatically();PushNotices.foreground=true;if(BuildConfig.FIREBASE_CONFIGURED)PushRegistry.bind(this,com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid)}
    override fun onPause(){PushNotices.foreground=false;super.onPause()}
    private fun signIn() {
        if(!BuildConfig.FIREBASE_CONFIGURED) { model?.error = "Sign-in is temporarily unavailable. You can still listen to music and use your downloads."; return }
        val res = resources.getIdentifier("default_web_client_id","string",packageName)
        if(res == 0) { model?.error = "Sign-in is temporarily unavailable. Please try again later."; return }
        val options = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN).requestIdToken(getString(res)).requestEmail().build()
        signInLauncher.launch(GoogleSignIn.getClient(this,options).signInIntent)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState);messageIntent.value=intent.getStringExtra("chatPeer"); enableEdgeToEdge(statusBarStyle=SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),navigationBarStyle=SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        if(Build.VERSION.SDK_INT >= 33) permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        setContent {
            val vm: CapyModel = viewModel(); val social: SocialModel = viewModel(); model = vm
            LaunchedEffect(vm.user?.uid) { vm.collaboration=social;social.bind(vm.db,vm.user?.uid);PushRegistry.bind(this@MainActivity,vm.user?.uid) }
            LaunchedEffect(social.sharedPlaylists,vm.user?.uid){vm.applySharedCollections(social.sharedPlaylists)}
            LaunchedEffect(vm.current?.playableID,vm.playing,social.sharingActivity,vm.user?.uid){while(true){social.publishActivity(vm.current,vm.playing);if(!vm.playing)break;kotlinx.coroutines.delay(60000)}}
            MaterialTheme(colorScheme = darkColorScheme(primary=Violet,secondary=Color(0xFFD78FEE),background=Night,surface=Raised,onPrimary=Night)) {
                CompositionLocalProvider(LocalContentColor provides Color.White) { CapyApp(vm,social,::signIn,messageIntent.value){messageIntent.value=null} }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun CapyApp(vm: CapyModel,social: SocialModel,signIn: () -> Unit,requestedPeer:String?=null,onPeerConsumed:()->Unit={}) {
    var tab by remember { mutableStateOf("Home") }
    var query by rememberSaveable { mutableStateOf("") }
    var albumsOnly by rememberSaveable { mutableStateOf(false) }
    var selectedAlbum by remember { mutableStateOf<Album?>(null) }
    var showPlayer by remember { mutableStateOf(false) }
    var showRecent by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var settingsStartPage by remember { mutableStateOf("CapyFlow") }
    val updater:AppUpdater=viewModel();val updateContext=LocalContext.current
    val searchPrefs = remember { updateContext.getSharedPreferences("capyflow-search-history", android.content.Context.MODE_PRIVATE) }
    var songHistory by remember { mutableStateOf(loadSearchHistory(searchPrefs, "songs")) }
    var albumHistory by remember { mutableStateOf(loadSearchHistory(searchPrefs, "albums")) }
    fun rememberSearch(term: String) {
        val clean = term.trim()
        if(clean.isEmpty()) return
        val key = if(albumsOnly) "albums" else "songs"
        val current = if(albumsOnly) albumHistory else songHistory
        val updated = (listOf(clean) + current.filterNot { it.equals(clean, ignoreCase=true) }).take(10)
        saveSearchHistory(searchPrefs,key,updated)
        if(albumsOnly) albumHistory=updated else songHistory=updated
    }
    updater.announcement?.let{update->AlertDialog(onDismissRequest={updater.later()},title={Text("Update available · ${update.name}")},text={Column(Modifier.heightIn(max=300.dp).verticalScroll(rememberScrollState())){Text("What’s new",fontWeight=FontWeight.Bold);Spacer(Modifier.height(10.dp));Text(update.notes.ifBlank{"A new CapyFlow update is ready."})}},confirmButton={TextButton(onClick={updater.acceptAnnouncement();settingsStartPage="Updates";showSettings=true;updater.download(updateContext)}){Text("Update now")}},dismissButton={TextButton(onClick={updater.later()}){Text("Later")}})}
    var showQueue by remember { mutableStateOf(false) }
    var showNewPlaylist by remember { mutableStateOf(false) }
    var selectedPlaylist by remember { mutableStateOf<String?>(null) }
    var addTrack by remember { mutableStateOf<Track?>(null) }
    var selectedProfile by remember { mutableStateOf<Profile?>(null) }
    var chatPeer by remember { mutableStateOf<String?>(null) }
    var showGlobalChat by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var notice by remember{mutableStateOf<AppNotice?>(null)}
    var noticeDrag by remember(notice?.id){mutableFloatStateOf(0f)}
    val noticeOffset by animateFloatAsState(noticeDrag,spring(stiffness=Spring.StiffnessHigh),label="notification swipe")
    val dismissDistance=with(LocalDensity.current){32.dp.toPx()}
    LaunchedEffect(vm.user?.uid){chatPeer=null;selectedProfile=null;social.clearPeopleSearch()}
    LaunchedEffect(requestedPeer,vm.user?.uid){if(requestedPeer!=null && vm.user!=null && requestedPeer!=vm.user?.uid){if(requestedPeer=="global-chat"){showGlobalChat=true}else{social.openChat(requestedPeer);chatPeer=requestedPeer};onPeerConsumed()}}
    GlobalChatAlerts(vm.user?.uid,showGlobalChat){notice=it}
    LaunchedEffect(social,vm.user?.uid){social.notices.collect{event->
        if(event.peerID==null || ChatPreferences.enabled(updateContext,"messageBanners")){
            val person=event.peerID?.let{id->social.friends[id] ?: try{social.profile(id)}catch(_:Exception){null}}
            if(event.peerID==null || ChatPreferences.enabled(updateContext,"messageBanners"))notice=event.copy(profile=person)
        }
    }}
    LaunchedEffect(Unit){PushNotices.events.collect{notice=it}}
    LaunchedEffect(notice?.id){if(notice!=null){kotlinx.coroutines.delay(4000);notice=null}}
    LaunchedEffect(vm.error,social.error){(vm.error ?: social.error)?.let{notice=AppNotice("CapyFlow",it);vm.error=null;social.error=null}}
    Box(Modifier.fillMaxSize().background(Night)) {
        AmbientBackground()
        Scaffold(containerColor=Color.Transparent,bottomBar={
            Column(Modifier.navigationBarsPadding().padding(horizontal=16.dp,vertical=8.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
                vm.current?.let { t -> MiniPlayer(t,vm,{showPlayer=true}) }
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(30.dp)).background(Glass).border(1.dp,Color.White.copy(alpha=.12f),RoundedCornerShape(30.dp)).padding(5.dp),horizontalArrangement=Arrangement.SpaceEvenly) {
                    listOf("Home" to Icons.Default.Home,"Search" to Icons.Default.Search,"Library" to Icons.Default.LibraryMusic,"Social" to Icons.Default.People,"Messages" to Icons.Default.Forum).forEach { (label,icon) ->
                        Column(Modifier.weight(1f).clip(RoundedCornerShape(24.dp)).background(if(tab==label)Violet.copy(alpha=.16f) else Color.Transparent).clickable { tab=label; selectedPlaylist=null }.padding(vertical=10.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                            Icon(icon,label,tint=if(tab==label)Violet else Color.White.copy(alpha=.55f),modifier=Modifier.size(22.dp)); Text(label,color=if(tab==label)Violet else Color.White.copy(alpha=.6f),fontSize=11.sp,fontWeight=FontWeight.SemiBold)
                        }
                    }
                }
            }
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).widthIn(max=652.dp).align(Alignment.TopCenter).padding(horizontal=16.dp)) {
                if(tab!="Library") Row(Modifier.fillMaxWidth().padding(top=12.dp,bottom=20.dp),verticalAlignment=Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("CAPYFLOW",color=Violet,fontSize=11.sp,fontWeight=FontWeight.Black,letterSpacing=3.sp); Text(if(selectedPlaylist!=null)vm.playlists.firstOrNull{it.id==selectedPlaylist}?.name ?: "Playlist" else tab,fontSize=32.sp,fontWeight=FontWeight.Bold) }
                    IconButton(onClick={showSettings=true},modifier=Modifier.clip(CircleShape).background(Glass)) { ProfileAvatar(social.ownProfile,36,"Profile and settings") }
                }
                when(tab) {
                    "Home" -> LazyColumn(verticalArrangement=Arrangement.spacedBy(20.dp)) {
                        item { Surface(shape=RoundedCornerShape(30.dp),color=Violet.copy(alpha=.10f)) { Column(Modifier.fillMaxWidth().padding(24.dp)) { Text("YOUR NEXT FAVORITE",color=Violet,fontSize=11.sp,letterSpacing=2.sp);Text("Find your flow.",fontSize=32.sp,fontWeight=FontWeight.Bold); Text("Your music. Your people. All in one place.",color=Color.White.copy(alpha=.65f),modifier=Modifier.padding(top=8.dp)); Button(onClick={tab="Search"},modifier=Modifier.padding(top=16.dp)) { Icon(Icons.Default.Search,null); Spacer(Modifier.width(8.dp)); Text("Explore music") } } } }
                        if(vm.playlists.isNotEmpty()) {
                            item { Section("Your playlists") }
                            item { LazyRow(horizontalArrangement=Arrangement.spacedBy(12.dp)) { items(vm.playlists,key={it.id}) { p -> Column(Modifier.width(145.dp).clickable { selectedPlaylist=p.id; tab="Library" }) { PlaylistCover(p,145,social.sharedFor(p)!=null); Text(p.name,fontWeight=FontWeight.Bold,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.padding(top=10.dp)); Text("${p.tracks.size} songs",fontSize=12.sp,color=Color.White.copy(alpha=.6f));PlaylistDownloadBadge(p,vm) } } } }
                        }
                        if(vm.recentTracks.isNotEmpty()){
                            item{Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Text("Recently played",fontSize=23.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f));TextButton(onClick={showRecent=true}){Text("Show more")}}}
                            item{LazyRow(horizontalArrangement=Arrangement.spacedBy(12.dp)){items(vm.recentTracks.take(6),key={it.playableID}){t->
                                Column(Modifier.width(124.dp).clickable{vm.play(t,vm.recentTracks.take(20))}){
                                    Artwork(t.artwork,124)
                                    Text(t.title,fontWeight=FontWeight.SemiBold,maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=14.sp,modifier=Modifier.padding(top=8.dp))
                                    Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(5.dp)){if(vm.hasDownload(t))Icon(Icons.Default.DownloadForOffline,"Downloaded",tint=Violet,modifier=Modifier.size(14.dp));if(t.isExplicit==true)ExplicitBadge();Text(t.artist,fontSize=12.sp,maxLines=1,overflow=TextOverflow.Ellipsis,color=Color.White.copy(alpha=.6f))}
                                }
                            }}}
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
                            OutlinedTextField(query,{query=it},placeholder={Text(if(albumsOnly)"Search albums or artists" else "Search songs or artists")},singleLine=true,modifier=Modifier.fillMaxWidth().padding(top=12.dp),shape=RoundedCornerShape(24.dp),trailingIcon={IconButton(onClick={rememberSearch(query);vm.search(query,albumsOnly)}){Icon(Icons.Default.Search,"Search")}})
                            LaunchedEffect(query,albumsOnly){kotlinx.coroutines.delay(400);vm.search(query,albumsOnly)}
                            if(vm.searching)LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical=12.dp))
                            LazyColumn(Modifier.padding(top=12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                                if(query.isBlank()){
                                    val history=if(albumsOnly)albumHistory else songHistory
                                    item { Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Text("Recent searches",fontSize=21.sp,fontWeight=FontWeight.Bold);Text(if(albumsOnly)"Albums" else "Songs",fontSize=12.sp,color=Color.White.copy(alpha=.55f))};if(history.isNotEmpty())TextButton(onClick={saveSearchHistory(searchPrefs,if(albumsOnly)"albums" else "songs",emptyList());if(albumsOnly)albumHistory=emptyList() else songHistory=emptyList()}){Text("Clear")}} }
                                    if(history.isEmpty())item{EmptyState("No recent searches","Your recent searches will appear here.",Icons.Default.History)}
                                    else items(history,key={it}){term->Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Glass).padding(start=14.dp),verticalAlignment=Alignment.CenterVertically){Row(Modifier.weight(1f).clickable{query=term;vm.search(term,albumsOnly)}.padding(vertical=15.dp),verticalAlignment=Alignment.CenterVertically){Icon(Icons.Default.History,null,tint=Violet);Spacer(Modifier.width(12.dp));Text(term,maxLines=1,overflow=TextOverflow.Ellipsis)};IconButton(onClick={val updated=history.filterNot{it==term};saveSearchHistory(searchPrefs,if(albumsOnly)"albums" else "songs",updated);if(albumsOnly)albumHistory=updated else songHistory=updated}){Icon(Icons.Default.Close,"Remove")}}}
                                }
                                else if(!vm.searching && (if(albumsOnly)vm.albums.isEmpty() else vm.results.isEmpty()))item{EmptyState("No results found","Try another title or artist.",Icons.Default.Search)}
                                if(albumsOnly)items(vm.albums,key={it.id}){a -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Glass).clickable{selectedAlbum=a;vm.openAlbum(a)}.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(a.artwork,72);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(a.title,fontWeight=FontWeight.Bold);Text(a.artist,color=Violet,fontSize=13.sp);a.year?.let{Text(it,fontSize=12.sp)}};Icon(Icons.Default.ChevronRight,null)} }
                                else items(vm.results,key={it.id}){t -> TrackRow(t,{vm.play(t,vm.results)},vm,{addTrack=t})}
                            }
                        }
                    }
                    "Library" -> AnimatedContent(targetState=selectedPlaylist,transitionSpec={
                        if(targetState!=null) (slideInHorizontally(tween(340),initialOffsetX={it})+fadeIn(tween(220))) togetherWith (slideOutHorizontally(tween(340),targetOffsetX={-it/4})+fadeOut(tween(220)))
                        else (slideInHorizontally(tween(320),initialOffsetX={-it/4})+fadeIn(tween(220))) togetherWith (slideOutHorizontally(tween(320),targetOffsetX={it})+fadeOut(tween(220)))
                    },label="Playlist navigation") { id ->
                        BackHandler(enabled=id!=null){selectedPlaylist=null}
                        val playlist=vm.playlists.firstOrNull{it.id==id} ?: social.sharedPlaylists.firstOrNull{"cloud:"+it.id==id}?.imported()
                        if(playlist!=null) PlaylistScreen(vm,social,playlist,{selectedPlaylist=null},{tab="Search";selectedPlaylist=null},{addTrack=it},{selectedProfile=it})
                        else LibraryScreen(vm,social,{selectedPlaylist=it},{showNewPlaylist=true},{showSettings=true},{addTrack=it})
                    }
                    "Messages" -> {if(vm.user==null)Button(onClick=signIn){Text("Sign in to message")}else MessagesScreen(social){social.openChat(it);chatPeer=it}}
                    "Social" -> {
                        if(vm.user == null) Column { EmptyState("Listen together","Sign in with the same Google account you use on iOS.",Icons.Default.People); Button(onClick=signIn,modifier=Modifier.fillMaxWidth()) {Text("Continue with Google")} }
                        else SocialScreen(social,vm,onProfile={selectedProfile=it})
                    }
                }
            }
        }
        AnimatedVisibility(showRecent,enter=slideInHorizontally(tween(300),initialOffsetX={it}),exit=slideOutHorizontally(tween(260),targetOffsetX={it})){
            BackHandler{showRecent=false}
            Box(Modifier.fillMaxSize().background(Night)){AmbientBackground();Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(16.dp)){
                Row(verticalAlignment=Alignment.CenterVertically){IconButton(onClick={showRecent=false}){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Text("Recently played",fontSize=25.sp,fontWeight=FontWeight.Bold)}
                Text("Your latest 20 songs",color=Color.White.copy(alpha=.55f),fontSize=12.sp,modifier=Modifier.padding(start=12.dp,bottom=12.dp))
                LazyColumn(Modifier.weight(1f)){items(vm.recentTracks.take(20),key={it.playableID}){t->TrackRow(t,{vm.play(t,vm.recentTracks.take(20))},vm,{addTrack=t})}}
            }}
        }
        AnimatedVisibility(showPlayer,enter=slideInVertically(tween(320),initialOffsetY={it})+fadeIn(tween(180)),exit=slideOutVertically(tween(280),targetOffsetY={it})+fadeOut(tween(240))) {
            BackHandler(enabled=showPlayer){showPlayer=false}
            PlayerScreen(vm,{showPlayer=false},{showQueue=true},{vm.current?.let{addTrack=it}})
        }
        AnimatedContent(targetState=chatPeer,modifier=Modifier.fillMaxSize(),transitionSpec={
            if(targetState!=null)(slideInHorizontally(tween(320),initialOffsetX={it})+fadeIn()) togetherWith fadeOut(tween(120))
            else fadeIn(tween(120)) togetherWith (slideOutHorizontally(tween(280),targetOffsetX={it})+fadeOut())
        },label="Chat navigation"){id->if(id!=null){
            BackHandler{social.closeChat();chatPeer=null}
            Box(Modifier.fillMaxSize().background(Night)){AmbientBackground();ChatScreen(id,vm,social,{selectedProfile=it}){social.closeChat();chatPeer=null}}
        }}
        if(showGlobalChat)Box(Modifier.fillMaxSize().background(Night)){AmbientBackground();GlobalChatScreen(vm,social,signIn,{selectedProfile=it},{showPlayer=true}){showGlobalChat=false}}
        AnimatedVisibility(showSettings,enter=fadeIn(tween(200)),exit=fadeOut(tween(200))){Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha=.55f)).clickable{showSettings=false})}
        AnimatedVisibility(showSettings,enter=slideInHorizontally(tween(300),initialOffsetX={-it}),exit=slideOutHorizontally(tween(260),targetOffsetX={-it})){
            AccountDrawer(vm,social,signIn,{showSettings=false;settingsStartPage="CapyFlow"},{selectedProfile=it},{tab="Social";showSettings=false},{tab="Messages";showSettings=false},{showGlobalChat=true;showSettings=false},settingsStartPage)
        }
        AnimatedVisibility(notice!=null,modifier=Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(12.dp)
            .offset { IntOffset(0,noticeOffset.toInt()) }
            .pointerInput(notice?.id) {
                detectVerticalDragGestures(onDragEnd={if(noticeDrag < -dismissDistance)notice=null;noticeDrag=0f},onDragCancel={noticeDrag=0f}) { change, amount ->
                    if(amount<0 || noticeDrag<0){change.consume();noticeDrag=(noticeDrag+amount).coerceAtMost(0f)}
                }
            },enter=slideInVertically(initialOffsetY={-it})+fadeIn(),exit=slideOutVertically(targetOffsetY={-it})+fadeOut()){
            notice?.let{n->Surface(shape=RoundedCornerShape(24.dp),color=Raised,tonalElevation=8.dp,shadowElevation=8.dp){Row(Modifier.fillMaxWidth().clickable{if(n.global)showGlobalChat=true;n.peerID?.let{if(vm.user!=null){social.openChat(it);chatPeer=it}};notice=null}.padding(16.dp),verticalAlignment=Alignment.CenterVertically){if(n.profile!=null)ProfileAvatar(n.profile,42) else Icon(if(n.peerID!=null)Icons.Default.Forum else Icons.Default.Info,null,tint=Violet);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(n.profile?.displayName ?: n.title,fontWeight=FontWeight.Bold,color=Violet);if(n.global)Text("Global Chat",fontSize=11.sp,color=Color.White.copy(alpha=.55f));Text(n.body,maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=13.sp)};IconButton(onClick={notice=null}){Icon(Icons.Default.Close,"Dismiss notification")}}}}
        }
    }
    if(showQueue) ModalBottomSheet(onDismissRequest={showQueue=false},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night) { QueueSheet(vm) }
    if(showNewPlaylist) { var name by remember {mutableStateOf("")}; AlertDialog(onDismissRequest={showNewPlaylist=false},title={Text("New playlist")},text={OutlinedTextField(name,{name=it},label={Text("Playlist name")})},confirmButton={TextButton(onClick={val id=vm.createPlaylist(name);if(id!=null)addTrack?.let{vm.addToPlaylist(id,it)};addTrack=null;showNewPlaylist=false},enabled=name.isNotBlank()) {Text("Create")}},dismissButton={TextButton(onClick={showNewPlaylist=false}) {Text("Cancel")}}) }
    addTrack?.takeUnless{showNewPlaylist}?.let { t -> ModalBottomSheet(onDismissRequest={addTrack=null},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night) {
        Column(Modifier.fillMaxWidth().padding(20.dp).navigationBarsPadding()) {Section("Add to playlist");Row(Modifier.padding(vertical=12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(t.artwork,48);Column(Modifier.padding(start=12.dp)){Text(t.title,maxLines=1,overflow=TextOverflow.Ellipsis);Text(t.artist,color=Violet,fontSize=12.sp)}}
            TextButton(onClick={showNewPlaylist=true},modifier=Modifier.fillMaxWidth()){Icon(Icons.Default.Add,null);Text("Create a new playlist")}
            LazyColumn(Modifier.heightIn(max=420.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){items(vm.playlists+social.sharedPlaylists.filter{it.ownerID!=vm.user?.uid}.map{it.imported()},key={it.id}){p -> val added=p.tracks.any{it.playableID==t.playableID};Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Glass).clickable(enabled=!added){vm.addToPlaylist(p.id,t);addTrack=null}.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(p.tracks.firstOrNull()?.artwork,56);Column(Modifier.weight(1f).padding(start=12.dp)){Text(p.name,fontWeight=FontWeight.Bold);Text(if(added)"Already added" else "${p.tracks.size} songs",fontSize=12.sp,color=Color.White.copy(alpha=.6f))};Icon(if(added)Icons.Default.CheckCircle else Icons.Default.Add,null,tint=Violet)} } }
        }
    } }
    selectedProfile?.let { p -> ProfilePreview(social,vm.user?.uid,p,{selectedProfile=null}){id->social.openChat(id);chatPeer=id;selectedProfile=null} }

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
        Artwork(track.artwork,56);Column(Modifier.weight(1f).padding(horizontal=12.dp)) {Text(track.title,maxLines=2,overflow=TextOverflow.Ellipsis,fontWeight=FontWeight.SemiBold,color=if(vm.current?.id==track.id)Violet else Color.White);Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(5.dp)){if(vm.hasDownload(track))Icon(Icons.Default.DownloadForOffline,"Downloaded",tint=Violet,modifier=Modifier.size(15.dp));if(track.isExplicit==true)ExplicitBadge();Text(track.artist,maxLines=1,overflow=TextOverflow.Ellipsis,fontSize=12.sp,color=Color.White.copy(alpha=.6f))}}
        if(track.playableID in vm.downloading)CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp)
        Box {IconButton(onClick={menu=true}) {Icon(Icons.Default.MoreVert,"Song options")};DropdownMenu(menu,{menu=false}) {DropdownMenuItem(text={Text("Play next")},onClick={vm.playNext(track);menu=false});DropdownMenuItem(text={Text("Add to queue")},onClick={vm.enqueue(track);menu=false});DropdownMenuItem(text={Text("Add to playlist")},onClick={onAdd();menu=false});DropdownMenuItem(text={Text(if(vm.hasDownload(track))"Downloaded" else "Download")},onClick={vm.download(track);menu=false});if(remove!=null)DropdownMenuItem(text={Text("Remove")},onClick={remove();menu=false})} }
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
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){IconButton(onClick=onClose){Icon(Icons.Default.KeyboardArrowDown,"Close player")};Column(Modifier.weight(1f),horizontalAlignment=Alignment.CenterHorizontally){Text("NOW PLAYING",fontSize=11.sp,letterSpacing=2.sp,fontWeight=FontWeight.Bold);AudioOutputButton()};IconButton(onClick=onAdd){Icon(Icons.Default.PlaylistAdd,"Add to playlist")}}
                Spacer(Modifier.height(12.dp));Artwork(track?.artwork,artSize)
                Column(Modifier.fillMaxWidth().padding(top=16.dp,bottom=4.dp)){Text(track?.title ?: "CapyFlow",fontSize=26.sp,fontWeight=FontWeight.Bold,maxLines=2,overflow=TextOverflow.Ellipsis);Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)){if(track?.isExplicit==true)ExplicitBadge();Text(track?.artist.orEmpty(),fontSize=16.sp,color=Color.White.copy(alpha=.66f),maxLines=1,overflow=TextOverflow.Ellipsis)}}
                Slider(value=scrub.coerceIn(0f,maxOf(vm.duration.toFloat(),1f)),onValueChange={scrubbing=true;scrub=it},onValueChangeFinished={vm.seek(scrub.toDouble());scrubbing=false},valueRange=0f..maxOf(vm.duration.toFloat(),1f),thumb={Box(Modifier.size(12.dp).background(Violet,CircleShape))},track={state -> SliderDefaults.Track(state,modifier=Modifier.height(4.dp),colors=SliderDefaults.colors(activeTrackColor=Violet,inactiveTrackColor=Color.White.copy(alpha=.14f)),drawStopIndicator=null,thumbTrackGapSize=0.dp)})
                Row(Modifier.fillMaxWidth()){Text(clock(if(scrubbing)scrub.toDouble() else vm.elapsed),fontSize=12.sp,color=Color.White.copy(alpha=.5f));Spacer(Modifier.weight(1f));Text("−"+clock((vm.duration-(if(scrubbing)scrub.toDouble() else vm.elapsed)).coerceAtLeast(0.0)),fontSize=12.sp,color=Color.White.copy(alpha=.5f))}
                Row(Modifier.padding(vertical=14.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(32.dp)){IconButton(onClick={vm.previous()},modifier=Modifier.size(52.dp)){Icon(Icons.Default.SkipPrevious,"Previous song",modifier=Modifier.size(32.dp))};FilledIconButton(onClick={vm.toggle()},modifier=Modifier.size(70.dp)){if(vm.loading)CircularProgressIndicator(Modifier.size(28.dp),color=Night) else Icon(if(vm.playing)Icons.Default.Pause else Icons.Default.PlayArrow,"Play or pause",modifier=Modifier.size(36.dp))};IconButton(onClick={vm.next()},enabled=vm.queue.isNotEmpty(),modifier=Modifier.size(52.dp)){Icon(Icons.Default.SkipNext,"Next song",modifier=Modifier.size(32.dp))}}
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                    PlayerAction("Repeat",if(vm.repeatSong)Icons.Default.RepeatOne else Icons.Default.Repeat,vm.repeatSong,Modifier.weight(1f)){vm.toggleRepeat()}
                    PlayerAction("Lyrics",Icons.Default.FormatQuote,showLyrics,Modifier.weight(1f)){showLyrics=!showLyrics}
                    val saved=track!=null && vm.downloads.any{it.playableID==track.playableID};val downloading=track?.playableID in vm.downloading
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
        Box(Modifier.fillMaxWidth().height(220.dp),contentAlignment=Alignment.CenterStart) {
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
    val state=rememberLazyListState();val scope=rememberCoroutineScope();val density=LocalDensity.current
    val edge=with(density){56.dp.toPx()}
    var dragging by remember{mutableStateOf<String?>(null)}
    var top by remember{mutableFloatStateOf(0f)};var draggedHeight by remember{mutableIntStateOf(0)}
    fun reorder() {
        val key=dragging ?: return;val index=vm.queueKeys.indexOf(key);if(index<0)return
        val center=top+draggedHeight/2
        val target=state.layoutInfo.visibleItemsInfo.firstOrNull{it.key!=key && center>=it.offset && center<=it.offset+it.size} ?: return
        if(target.index!=index) {
            val first=state.firstVisibleItemIndex;val offset=state.firstVisibleItemScrollOffset
            vm.moveQueue(index,target.index-index)
            // Keep the numeric viewport position when the first visible key changes.
            scope.launch{state.scrollToItem(first,offset)}
        }
    }
    LaunchedEffect(dragging) {
        while(dragging!=null) {
            val layout=state.layoutInfo;val center=top+draggedHeight/2
            val speed=when {center<layout.viewportStartOffset+edge -> -((layout.viewportStartOffset+edge-center)/edge).coerceIn(0f,1f)*12f;center>layout.viewportEndOffset-edge -> ((center-layout.viewportEndOffset+edge)/edge).coerceIn(0f,1f)*12f;else -> 0f}
            if(speed!=0f){state.scrollBy(speed);reorder()}
            kotlinx.coroutines.delay(16)
        }
    }
    Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal=20.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically){Column(Modifier.weight(1f)){Section("Up next");Text("Drag the handle to reorder · swipe left to remove",fontSize=11.sp,color=Color.White.copy(alpha=.5f))};TextButton(onClick={dragging=null;vm.clearQueue()}){Text("Clear")}}
        vm.current?.let{track -> Row(Modifier.fillMaxWidth().padding(vertical=16.dp),verticalAlignment=Alignment.CenterVertically){Artwork(track.artwork,48);Column(Modifier.padding(start=12.dp)){Text("NOW PLAYING",fontSize=10.sp,color=Violet,letterSpacing=1.sp);Text(track.title,maxLines=1,overflow=TextOverflow.Ellipsis)}}}
        LazyColumn(Modifier.fillMaxWidth().heightIn(max=480.dp),state=state,verticalArrangement=Arrangement.spacedBy(8.dp),contentPadding=PaddingValues(bottom=20.dp)) {
            items(vm.queue.size,key={vm.queueKeys[it]}){index ->
                val key=vm.queueKeys[index];val moving=key==dragging
                val targetOffset=if(moving)top-(state.layoutInfo.visibleItemsInfo.firstOrNull{it.key==key}?.offset ?: top.toInt()) else 0f
                val offset by animateFloatAsState(targetOffset,animationSpec=if(moving)snap() else tween(180,easing=FastOutSlowInEasing),label="Queue drop")
                QueueItem(vm,index,key,Modifier.animateItem(placementSpec=if(moving)null else tween(230,easing=FastOutSlowInEasing)).zIndex(if(moving)1f else 0f).offset{IntOffset(0,offset.toInt())},
                    onStart={state.layoutInfo.visibleItemsInfo.firstOrNull{it.key==key}?.let{dragging=key;top=it.offset.toFloat();draggedHeight=it.size}},
                    onDrag={top+=it;reorder()},onEnd={dragging=null})
            }
            if(vm.queue.isEmpty())item{EmptyState("You’re all caught up","Add a song to your queue.",Icons.AutoMirrored.Filled.QueueMusic)}
        }
    }
}
@Composable fun QueueItem(vm: CapyModel,index: Int,key: String,modifier: Modifier=Modifier,onStart:()->Unit,onDrag:(Float)->Unit,onEnd:()->Unit) {
    val track=vm.queue.getOrNull(index) ?: return;val density=LocalDensity.current;val reveal=with(density){80.dp.toPx()}
    var swipe by remember(key){mutableFloatStateOf(0f)}
    val latestStart by rememberUpdatedState(onStart);val latestDrag by rememberUpdatedState(onDrag);val latestEnd by rememberUpdatedState(onEnd)
    val animatedSwipe by animateFloatAsState(swipe,tween(160),label="Queue swipe")
    Box(modifier.fillMaxWidth().height(72.dp).clip(RoundedCornerShape(20.dp)).background(Color(0xFF652D42))) {
        TextButton(onClick={vm.queueKeys.indexOf(key).takeIf{it>=0}?.let{vm.removeQueue(it)}},modifier=Modifier.align(Alignment.CenterEnd).width(80.dp)){Text("Remove",color=Color.White,fontSize=12.sp)}
        Row(Modifier.fillMaxSize().offset{IntOffset(animatedSwipe.toInt(),0)}.background(Raised).pointerInput(key){detectHorizontalDragGestures(onDragEnd={swipe=if(swipe < -reveal/2)-reveal else 0f},onDragCancel={swipe=0f}){change,amount -> change.consume();swipe=(swipe+amount).coerceIn(-reveal,0f)}}.padding(horizontal=10.dp),verticalAlignment=Alignment.CenterVertically) {
            Artwork(track.artwork,48);Column(Modifier.weight(1f).padding(horizontal=12.dp).clickable{vm.queueKeys.indexOf(key).takeIf{it>=0}?.let{vm.removeQueue(it);vm.play(track)}}){Text(track.title,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis);Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(5.dp)){if(track.isExplicit==true)ExplicitBadge();Text(track.artist,fontSize=12.sp,color=Color.White.copy(alpha=.55f),maxLines=1,overflow=TextOverflow.Ellipsis)}}
            Icon(Icons.Default.DragHandle,"Drag to reorder",tint=Color.White.copy(alpha=.5f),modifier=Modifier.size(42.dp).pointerInput(key){detectDragGestures(onDragStart={swipe=0f;latestStart()},onDragEnd={latestEnd()},onDragCancel={latestEnd()}){change,amount -> change.consume();latestDrag(amount.y)}})
        }
    }
}
fun clock(seconds: Double): String {val value=if(seconds.isFinite())seconds.toInt().coerceAtLeast(0) else 0;return "%d:%02d".format(value/60,value%60)}
@Composable fun Settings(vm: CapyModel,signIn: ()->Unit) {
    var confirmSignOut by remember { mutableStateOf(false) }
    if(confirmSignOut) AlertDialog(onDismissRequest={confirmSignOut=false},title={Text("Sign out?")},text={Text("Your playlists stay saved to your account. You can sign in again anytime.")},confirmButton={TextButton(onClick={confirmSignOut=false;vm.signOut()}){Text("Sign out")}},dismissButton={TextButton(onClick={confirmSignOut=false}){Text("Cancel")}})
    var server by remember(vm.server){mutableStateOf(vm.server)}
    Column(Modifier.fillMaxWidth().padding(24.dp).navigationBarsPadding().verticalScroll(rememberScrollState())) {
        Section("Your CapyFlow")
        vm.user?.let{Text(it.displayName ?: "Signed in",fontSize=22.sp,fontWeight=FontWeight.Bold);Text(it.email ?: "",color=Violet);TextButton(onClick={confirmSignOut=true}){Text("Sign out")}} ?: Button(onClick=signIn,modifier=Modifier.fillMaxWidth()){Text("Continue with Google")}
        Section("Streaming connection");StreamingSettings(vm)
        if(vm.serverStatus.isNotBlank())Text(vm.serverStatus,color=Violet,fontSize=12.sp)
        Section("Audio quality");Text("Applies to the next stream or download. Saved tracks keep their downloaded quality.",fontSize=12.sp,color=Color.White.copy(alpha=.6f));Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){listOf("automatic","dataSaver").forEach{q -> FilterChip(vm.quality==q,{vm.saveQuality(q)},label={Text(if(q=="dataSaver")"Data saver" else "Best available")})}}
        Text("CapyFlow Android ${BuildConfig.VERSION_NAME}",color=Color.White.copy(alpha=.4f),fontSize=12.sp,modifier=Modifier.padding(top=24.dp))
    }
}
@Composable fun SocialScreen(social:SocialModel,vm:CapyModel,onProfile:(Profile)->Unit) {
    var query by remember(vm.user?.uid){mutableStateOf("")}
    DisposableEffect(Unit){onDispose{social.clearPeopleSearch()}}
    LaunchedEffect(query){if(query.isNotBlank()){kotlinx.coroutines.delay(350);social.findPeople(query)}}
    Column {
        OutlinedTextField(query,{query=it;social.clearPeopleSearch()},label={Text("Find people by username")},singleLine=true,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp),trailingIcon={if(query.isNotEmpty())IconButton(onClick={query="";social.clearPeopleSearch()}){Icon(Icons.Default.Close,"Clear user search")}else Icon(Icons.Default.Search,null)})
        if(social.searching)LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical=8.dp))
        LazyColumn(Modifier.padding(top=14.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
            if(query.isBlank()){
                item{Section("Following")}
                if(social.following.isEmpty())item{EmptyState("Find your people","Search for a CapyFlow username to follow someone.",Icons.Default.People)}
                items(social.following.toList(),key={it}){id->ContactCard(social,id,onProfile)}
            }else{
                if(!social.searching && social.profiles.isEmpty())item{Text("No people found",color=Color.White.copy(alpha=.6f))}
                items(social.profiles,key={it.id}){p->ContactCard(social,p.id,onProfile){person->IconButton(onClick={social.follow(person,person.id !in social.following)}){Icon(if(person.id in social.following)Icons.Default.PersonRemove else Icons.Default.PersonAdd,"Follow or unfollow",tint=Violet)}}}
            }
        }
    }
}
@Composable fun MessagesScreen(social:SocialModel,onChat:(String)->Unit){
    LazyColumn(verticalArrangement=Arrangement.spacedBy(12.dp)){
        if(social.inbox.isEmpty())item{EmptyState("Your conversations","Open someone’s profile, follow them, then tap Message.",Icons.Default.Forum)}
        items(social.inbox,key={it.id}){c->val p=liveProfile(social,c.peer)
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Glass).clickable{onChat(c.peer)}.padding(16.dp),verticalAlignment=Alignment.CenterVertically){ProfileAvatar(p,52);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(p?.displayName ?: "CapyFlow listener",fontWeight=FontWeight.Bold);Text(c.text,maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=13.sp,color=Color.White.copy(alpha=.6f));if(c.date>0)Text(java.text.SimpleDateFormat("MMM d · h:mm a",java.util.Locale.getDefault()).format(java.util.Date(c.date)),fontSize=11.sp,color=Violet)};if(c.unread)Box(Modifier.size(8.dp).background(Violet,CircleShape))}
        }
    }
}
@Composable fun ChatScreen(peer: String,vm: CapyModel,social: SocialModel,onProfile:(Profile)->Unit,onClose:()->Unit) {
    var draft by remember(peer){mutableStateOf("")};val profile=liveProfile(social,peer)
    val ordered=remember(social.messages){social.messages.reversed()}
    val list=rememberLazyListState()
    var chatPlayerOpen by remember(peer){mutableStateOf(false)}
    LaunchedEffect(social.messages.lastOrNull()?.id){if(list.firstVisibleItemIndex<=1)list.animateScrollToItem(0)}
    DisposableEffect(peer){PushNotices.activePeer=peer;onDispose{if(PushNotices.activePeer==peer)PushNotices.activePeer=null}}
    Column(Modifier.fillMaxSize().statusBarsPadding().imePadding().navigationBarsPadding().padding(16.dp)) {
        Row(verticalAlignment=Alignment.CenterVertically){IconButton(onClick=onClose){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Row(Modifier.clickable{profile?.let(onProfile)},verticalAlignment=Alignment.CenterVertically){ProfileAvatar(profile,40);Text(profile?.displayName ?: "Messages",fontSize=22.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(start=10.dp))}}
        LazyColumn(Modifier.weight(1f).fillMaxWidth(),state=list,verticalArrangement=Arrangement.spacedBy(10.dp),reverseLayout=true){
            itemsIndexed(ordered,key={_,m->m.id}){index,m ->
                Column {
                    if(index==ordered.lastIndex || chatDay(m.date)!=chatDay(ordered[index+1].date))Text(chatDateLabel(m.date),fontSize=12.sp,color=Color.White.copy(alpha=.55f),modifier=Modifier.fillMaxWidth().padding(vertical=10.dp))
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=if(m.sender==vm.user?.uid)Arrangement.End else Arrangement.Start){Column(Modifier.widthIn(max=280.dp).clip(RoundedCornerShape(20.dp)).background(if(m.sender==vm.user?.uid)Violet.copy(alpha=.22f) else Glass).padding(14.dp)){Text(m.text);Row(horizontalArrangement=Arrangement.spacedBy(6.dp)){if(m.date>0)Text(chatTime(m.date),fontSize=10.sp,color=Color.White.copy(alpha=.5f));if(m.sender==vm.user?.uid)Text(social.messageStatus(m),fontSize=10.sp,color=Color.White.copy(alpha=.5f))}}}
                }
            }
        }
        Column(Modifier.fillMaxWidth().padding(top=10.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            vm.current?.let{ChatMiniPlayer(it,vm){chatPlayerOpen=true}}
            Row(verticalAlignment=Alignment.CenterVertically){OutlinedTextField(draft,{if(it.length<=4000)draft=it},placeholder={Text("Message")},modifier=Modifier.weight(1f),shape=RoundedCornerShape(24.dp),maxLines=4);IconButton(onClick={val submitted=draft;social.send(submitted){if(draft==submitted)draft=""}},enabled=draft.isNotBlank()&&!social.sending){Icon(Icons.AutoMirrored.Filled.Send,"Send message",tint=Violet)}}
        }
    }
    if(chatPlayerOpen) {
        BackHandler{chatPlayerOpen=false}
        PlayerScreen(vm,{chatPlayerOpen=false},{},{})
    }
}
@Composable fun ChatMiniPlayer(track:Track,vm:CapyModel,onOpen:()->Unit){
    Row(Modifier.fillMaxWidth().height(58.dp).clip(RoundedCornerShape(20.dp)).background(Raised.copy(alpha=.96f)).border(1.dp,Color.White.copy(alpha=.12f),RoundedCornerShape(20.dp)).clickable(onClick=onOpen).padding(horizontal=8.dp),verticalAlignment=Alignment.CenterVertically){
        Artwork(track.artwork,42)
        Column(Modifier.weight(1f).padding(horizontal=9.dp)){Text(track.title,maxLines=1,overflow=TextOverflow.Ellipsis,fontWeight=FontWeight.SemiBold,fontSize=13.sp);Text(track.artist,maxLines=1,overflow=TextOverflow.Ellipsis,color=Violet,fontSize=11.sp)}
        if(vm.loading)CircularProgressIndicator(Modifier.size(20.dp),strokeWidth=2.dp) else IconButton(onClick={vm.toggle()},modifier=Modifier.size(40.dp)){Icon(if(vm.playing)Icons.Default.Pause else Icons.Default.PlayArrow,"Play or pause",tint=Violet,modifier=Modifier.size(22.dp))}
        IconButton(onClick={vm.next()},enabled=vm.queue.isNotEmpty(),modifier=Modifier.size(40.dp)){Icon(Icons.Default.SkipNext,"Next song",modifier=Modifier.size(21.dp))}
    }
}


@Composable fun ExplicitBadge(){Box(Modifier.size(14.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha=.65f)),contentAlignment=Alignment.Center){Text("E",fontSize=9.sp,lineHeight=9.sp,fontWeight=FontWeight.Bold,color=Night)}}
@Composable fun PlaylistDownloadBadge(playlist:Playlist,vm:CapyModel){
    if(playlist.tracks.isNotEmpty() && playlist.tracks.all{vm.hasDownload(it)})Icon(Icons.Default.DownloadForOffline,"All playlist songs downloaded",tint=Violet,modifier=Modifier.padding(top=4.dp).size(15.dp))
}
@Composable fun SharedBadge(label:String="Shared"){
    Row(Modifier.clip(CircleShape).background(Violet.copy(alpha=.16f)).padding(horizontal=8.dp,vertical=4.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(4.dp)){Icon(Icons.Default.Group,"Shared playlist",tint=Violet,modifier=Modifier.size(13.dp));Text(label,fontSize=11.sp,color=Violet,fontWeight=FontWeight.SemiBold)}
}
@Composable fun PlaylistCover(playlist:Playlist,size:Int,shared:Boolean=false){
    val url=playlist.artworkURL ?: playlist.tracks.firstOrNull()?.artwork
    Box(Modifier.size(size.dp)){
        if(url!=null)Artwork(url,size) else Box(Modifier.fillMaxSize().clip(RoundedCornerShape(if(size>100)28.dp else 18.dp)).background(Violet.copy(alpha=.12f)),contentAlignment=Alignment.Center){Icon(Icons.AutoMirrored.Filled.QueueMusic,null,tint=Violet,modifier=Modifier.size((size*.38f).dp))}
        if(shared)Box(Modifier.align(Alignment.BottomEnd).padding(4.dp).size(26.dp).clip(CircleShape).background(Raised).border(1.dp,Violet.copy(alpha=.6f),CircleShape),contentAlignment=Alignment.Center){Icon(Icons.Default.Group,"Shared playlist",tint=Violet,modifier=Modifier.size(17.dp))}
    }
}
@Composable fun LibraryScreen(vm: CapyModel,social:SocialModel,onOpen:(String)->Unit,onCreate:()->Unit,onProfile:()->Unit,onAdd:(Track)->Unit) {
    var filter by rememberSaveable{mutableStateOf("All")};var sort by rememberSaveable{mutableStateOf("Recently added")};var menu by remember{mutableStateOf(false)};var offline by rememberSaveable{mutableStateOf(false)}
    BackHandler(enabled=offline){offline=false}
    val collections=(if(filter=="Shared")social.sharedPlaylists.map{it.imported()} else vm.playlists+social.sharedPlaylists.filter{it.ownerID!=vm.user?.uid}.map{it.imported()}).filter{when(filter){"Albums" -> it.albumID!=null;"Playlists" -> it.albumID==null;else -> true}}.let{if(sort=="Name")it.sortedBy{p->p.name.lowercase()} else it.reversed()}
    LazyColumn(Modifier.fillMaxSize(),verticalArrangement=Arrangement.spacedBy(18.dp),contentPadding=PaddingValues(top=16.dp,bottom=24.dp)) {
        item{Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)){
            IconButton(onClick=onProfile,modifier=Modifier.size(44.dp).clip(CircleShape).background(Violet.copy(alpha=.15f))){ProfileAvatar(social.ownProfile,40,"Profile")}
            Column(Modifier.weight(1f)){Text(if(offline)"Downloads" else "Library",fontSize=30.sp,fontWeight=FontWeight.Bold);Text(if(offline)"${vm.downloads.size} available offline" else "Everything you made yours",fontSize=12.sp,color=Color.White.copy(alpha=.6f))}
            if(offline)IconButton(onClick={offline=false}){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back to library")} else {Box{IconButton(onClick={menu=true},modifier=Modifier.clip(CircleShape).background(Glass)){Icon(Icons.Default.SwapVert,"Sort library")};DropdownMenu(menu,{menu=false}){listOf("Recently added","Name").forEach{label -> DropdownMenuItem(text={Text(label)},onClick={sort=label;menu=false})}}};FilledIconButton(onClick=onCreate){Icon(Icons.Default.Add,"Create playlist")}}
        }}
        if(!offline)item{LazyRow(horizontalArrangement=Arrangement.spacedBy(8.dp)){items(listOf("All","Playlists","Albums","Downloaded","Shared")){label -> FilterChip(selected=filter==label,onClick={filter=label},label={Text(label)},shape=CircleShape)}}}
        if(!offline)item{Text(vm.cloudStatus,fontSize=12.sp,color=Color.White.copy(alpha=.55f))}
        if(offline || filter=="Downloaded") {
            if(vm.downloads.isEmpty())item{EmptyState("Your music, anywhere","Download a song from its menu to listen offline.",Icons.Default.DownloadForOffline)}
            items(vm.downloads,key={it.playableID}){t -> TrackRow(t,{vm.play(t,vm.downloads)},vm,{onAdd(t)},remove={vm.removeDownload(t)})}
        } else {
            item{Column{Section("Your collection");Text("${collections.size} saved",fontSize=12.sp,color=Color.White.copy(alpha=.55f))}}
            items(collections,key={it.id}){p -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).clickable{onOpen(p.id)}.padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically){PlaylistCover(p,68,social.sharedFor(p)!=null);Column(Modifier.weight(1f).padding(horizontal=14.dp)){Text(p.name,fontSize=18.sp,fontWeight=FontWeight.SemiBold);Text("${if(p.albumID!=null)"Album" else "Playlist"} · ${p.tracks.size} songs",fontSize=13.sp,color=Color.White.copy(alpha=.55f));Row(horizontalArrangement=Arrangement.spacedBy(6.dp)){if(social.sharedFor(p)!=null)SharedBadge();PlaylistDownloadBadge(p,vm)}};Icon(Icons.Default.ChevronRight,null,tint=Color.White.copy(alpha=.4f))}}
            if(collections.isEmpty())item{EmptyState("Make it yours","Create a playlist or save an album from Search.",Icons.AutoMirrored.Filled.QueueMusic)}
            if(filter=="All"){
                item{Column{Section("Downloaded");Text("${vm.downloads.size} available offline",fontSize=12.sp,color=Color.White.copy(alpha=.55f))}}
                item{Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(26.dp)).background(Glass).border(1.dp,Color.White.copy(alpha=.08f),RoundedCornerShape(26.dp)).clickable{offline=true}.padding(18.dp),verticalAlignment=Alignment.CenterVertically){Box(Modifier.size(54.dp).clip(RoundedCornerShape(16.dp)).background(Violet.copy(alpha=.12f)),contentAlignment=Alignment.Center){Icon(Icons.Default.DownloadForOffline,null,tint=Violet)};Column(Modifier.weight(1f).padding(horizontal=14.dp)){Text("Offline music",fontSize=18.sp,fontWeight=FontWeight.Bold);Text("Download songs to listen anywhere",fontSize=12.sp,color=Color.White.copy(alpha=.55f))};Icon(Icons.Default.ChevronRight,null,tint=Color.White.copy(alpha=.4f))}}
            }
        }
    }
}
@Composable fun PlaylistScreen(vm: CapyModel,social:SocialModel,playlist: Playlist,onClose:()->Unit,onSearch:()->Unit,onAdd:(Track)->Unit,onProfile:(Profile)->Unit) {
    var menu by remember{mutableStateOf(false)};var rename by remember{mutableStateOf(false)};var delete by remember{mutableStateOf(false)};var songPicker by remember{mutableStateOf(false)};var collaborate by remember{mutableStateOf(false)};var deleteShared by remember{mutableStateOf(false)}
    val shared=social.sharedFor(playlist);val isOwner=shared==null || shared.ownerID==vm.user?.uid
    val creator=liveProfile(social,shared?.ownerID ?: playlist.ownerID ?: vm.user?.uid)
    val context=LocalContext.current
    val artwork=rememberLauncherForActivityResult(ActivityResultContracts.GetContent()){uri -> uri?.let{vm.setPlaylistArtwork(playlist.id,it)}}
    LazyColumn(Modifier.fillMaxSize(),verticalArrangement=Arrangement.spacedBy(18.dp),contentPadding=PaddingValues(top=12.dp,bottom=24.dp)) {
        item{Row(verticalAlignment=Alignment.CenterVertically){TextButton(onClick=onClose){Icon(Icons.AutoMirrored.Filled.ArrowBack,null);Text("Back")};Text(playlist.name,fontSize=18.sp,fontWeight=FontWeight.Bold,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f));Box{IconButton(onClick={menu=true}){Icon(Icons.Default.MoreHoriz,"Playlist options",tint=Violet)};DropdownMenu(menu,{menu=false}){
            DropdownMenuItem(text={Text("Rename playlist")},enabled=isOwner,onClick={menu=false;rename=true})
            DropdownMenuItem(text={Text("Share playlist")},onClick={menu=false;val message="${playlist.name}\n"+playlist.tracks.joinToString("\n"){"${it.title} — ${it.artist}"};context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT,message),"Share playlist"))})
            DropdownMenuItem(text={Text("Remove playlist downloads")},enabled=playlist.tracks.any{vm.hasDownload(it)},onClick={menu=false;playlist.tracks.forEach{vm.removeDownload(it)}})
            if(shared!=null)DropdownMenuItem(text={Text(if(isOwner)"Delete shared playlist" else "Leave shared playlist")},onClick={menu=false;deleteShared=true})
            if(isOwner)DropdownMenuItem(text={Text("Delete playlist")},onClick={menu=false;delete=true})
        }}}}
        item{Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){PlaylistCover(playlist,140,shared!=null);Column(Modifier.weight(1f).padding(start=18.dp)){Text(if(playlist.albumID!=null)"ALBUM" else "PLAYLIST",fontSize=11.sp,letterSpacing=3.sp,color=Violet,fontWeight=FontWeight.Bold);Text(playlist.name,fontSize=27.sp,fontWeight=FontWeight.Bold,maxLines=3,overflow=TextOverflow.Ellipsis,modifier=Modifier.padding(vertical=8.dp));Text(creator?.username?.let{"By @$it"} ?: if(vm.user==null && shared==null)"By you" else "Loading creator…",fontSize=13.sp,color=Color.White.copy(alpha=.65f));Text("${playlist.tracks.size} songs",fontSize=12.sp,color=Color.White.copy(alpha=.5f),modifier=Modifier.padding(top=6.dp));if(shared!=null)Box(Modifier.padding(top=8.dp).clickable{collaborate=true}){SharedBadge("Shared playlist · ${shared.memberIDs.size} people")}}}}
        item{Row(horizontalArrangement=Arrangement.spacedBy(10.dp)){
            Button(onClick={playlist.tracks.firstOrNull()?.let{vm.play(it,playlist.tracks)}},enabled=playlist.tracks.isNotEmpty(),shape=CircleShape,modifier=Modifier.weight(1f).height(48.dp)){Icon(Icons.Default.PlayArrow,null);Text("Play",modifier=Modifier.padding(start=8.dp))}
            OutlinedButton(onClick={val shuffled=playlist.tracks.shuffled();shuffled.firstOrNull()?.let{vm.play(it,shuffled)}},enabled=playlist.tracks.isNotEmpty(),shape=CircleShape,modifier=Modifier.weight(1f).height(48.dp)){Icon(Icons.Default.Shuffle,null);Text("Shuffle",modifier=Modifier.padding(start=8.dp))}
        }}
        item{Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(6.dp)){
            PlayerAction("Add songs",Icons.Default.Add,false,Modifier.weight(1f)){songPicker=true}
            val allSaved=playlist.tracks.isNotEmpty() && playlist.tracks.all{vm.hasDownload(it)}
            val saving=playlist.tracks.any{it.playableID in vm.downloading}
            PlayerAction(if(allSaved)"Downloaded" else if(saving)"Saving…" else "Download",if(allSaved)Icons.Default.CheckCircle else Icons.Default.DownloadForOffline,allSaved,Modifier.weight(1f)){if(!allSaved)vm.downloadAll(playlist.tracks)}
            if(isOwner && !playlist.id.startsWith("cloud:"))PlayerAction("Artwork",Icons.Default.AddPhotoAlternate,false,Modifier.weight(1f)){artwork.launch("image/*")}
            PlayerAction(if(shared!=null)"Manage" else "Collaborate",if(shared!=null)Icons.Default.Group else Icons.Default.GroupAdd,shared!=null,Modifier.weight(1f)){collaborate=true}
        }}
        val failed=playlist.tracks.filter{it.playableID in vm.downloadFailures}
        if(failed.isNotEmpty())item{Column{Text("Couldn’t download: "+failed.joinToString{it.title},fontSize=12.sp,color=Violet);TextButton(onClick={vm.retryFailedDownloads(failed)}){Text("Retry failed songs")}}}
        item{Column{Section("Songs");Text(if(playlist.tracks.isEmpty())"Add music from Search" else "Tap a row to play",fontSize=12.sp,color=Color.White.copy(alpha=.55f))}}
        if(playlist.tracks.isEmpty())item{Surface(shape=RoundedCornerShape(28.dp),color=Glass){Column(Modifier.padding(20.dp)){EmptyState("This playlist is ready","Find a song in Search, open its menu, then choose Add to playlist.",Icons.AutoMirrored.Filled.QueueMusic);TextButton(onClick=onSearch,modifier=Modifier.align(Alignment.CenterHorizontally)){Text("Find songs")}}}}
        items(playlist.tracks,key={it.id}){t -> TrackRow(t,{vm.play(t,playlist.tracks)},vm,{onAdd(t)},remove={vm.removeFromPlaylist(playlist.id,t.id)})}
    }
    if(rename){var name by remember{mutableStateOf(playlist.name)};AlertDialog(onDismissRequest={rename=false},title={Text("Rename playlist")},text={OutlinedTextField(name,{name=it},singleLine=true)},confirmButton={TextButton(onClick={vm.renamePlaylist(playlist.id,name);rename=false},enabled=name.isNotBlank()){Text("Save")}},dismissButton={TextButton(onClick={rename=false}){Text("Cancel")}})}
    if(delete)AlertDialog(onDismissRequest={delete=false},title={Text("Delete playlist?")},text={Text(if(shared!=null)"This removes the playlist from My Playlists and Shared Playlists for everyone. Downloaded songs stay on this device." else "Downloaded songs will stay on this device.")},confirmButton={TextButton(onClick={vm.deletePlaylist(playlist.id);delete=false;onClose()}){Text("Delete")}},dismissButton={TextButton(onClick={delete=false}){Text("Cancel")}})
    if(deleteShared && shared!=null)AlertDialog(onDismissRequest={deleteShared=false},title={Text(if(isOwner)"Delete shared playlist?" else "Leave shared playlist?")},text={Text(if(isOwner)"Collaborators will lose access. Your personal playlist keeps all its latest songs." else "You will lose access to this shared playlist.")},confirmButton={TextButton(onClick={if(isOwner)social.deleteShared(shared){vm.keepPersonalCopy(shared);deleteShared=false;if(playlist.id.startsWith("cloud:"))onClose()}else{social.removeMember(shared,vm.user!!.uid);deleteShared=false;onClose()}}){Text(if(isOwner)"Delete shared playlist" else "Leave")}},dismissButton={TextButton(onClick={deleteShared=false}){Text("Cancel")}})
    if(collaborate)CollaborateSheet(vm,social,playlist,{collaborate=false},onProfile)
    if(songPicker) PlaylistSongPicker(vm,playlist,{songPicker=false},onSearch)
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun PlaylistSongPicker(vm: CapyModel,playlist: Playlist,onClose:()->Unit,onSearch:()->Unit){
    var query by remember{mutableStateOf("")};var albums by remember{mutableStateOf(false)};var selected by remember{mutableStateOf<Album?>(null)}
    LaunchedEffect(query,albums){kotlinx.coroutines.delay(400);vm.search(query,albums)}
    ModalBottomSheet(onDismissRequest={vm.closeAlbum();onClose()},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night){Column(Modifier.fillMaxWidth().padding(20.dp).navigationBarsPadding()){
        Section("Add songs")
        Row(horizontalArrangement=Arrangement.spacedBy(10.dp)){FilterChip(!albums,{albums=false;selected=null},label={Text("Songs")});FilterChip(albums,{albums=true;selected=null},label={Text("Albums")})}
        if(selected!=null){Row(verticalAlignment=Alignment.CenterVertically){TextButton(onClick={selected=null;vm.closeAlbum()}){Icon(Icons.AutoMirrored.Filled.ArrowBack,null);Text("Albums")};Text(selected!!.title,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f));TextButton(onClick={vm.addTracksToPlaylist(playlist.id,vm.albumTracks)}){Text("Add all")}}}
        else OutlinedTextField(query,{query=it},placeholder={Text(if(albums)"Search albums or artists" else "Search songs or artists")},singleLine=true,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(24.dp))
        if(vm.searching||vm.albumLoading)LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(Modifier.heightIn(max=420.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            if(albums && selected==null)items(vm.albums,key={it.id}){a -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Glass).clickable{selected=a;vm.openAlbum(a)}.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(a.artwork,56);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(a.title,fontWeight=FontWeight.Bold);Text(a.artist,fontSize=12.sp,color=Violet)};Icon(Icons.Default.ChevronRight,null)}}
            else items(if(selected!=null)vm.albumTracks else if(query.isBlank())vm.downloads else vm.results,key={it.playableID}){t -> val added=playlist.tracks.any{it.playableID==t.playableID};Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Glass).padding(12.dp),verticalAlignment=Alignment.CenterVertically){Artwork(t.artwork,48);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(t.title,maxLines=1,overflow=TextOverflow.Ellipsis);Text(t.artist,color=Color.White.copy(alpha=.6f),fontSize=12.sp)};IconButton(onClick={vm.addToPlaylist(playlist.id,t)},enabled=!added){Icon(if(added)Icons.Default.CheckCircle else Icons.Default.Add,if(added)"Added" else "Add song",tint=Violet)}}}
        }
        TextButton(onClick={vm.closeAlbum();onClose();onSearch()}){Text("Open Search")}
    }}
}


private fun loadSearchHistory(prefs: android.content.SharedPreferences,key:String):List<String>{
    return prefs.getString(key,"").orEmpty().split("\u001F").filter{it.isNotBlank()}.take(10)
}
private fun saveSearchHistory(prefs: android.content.SharedPreferences,key:String,values:List<String>){
    prefs.edit().putString(key,values.take(10).joinToString("\u001F")).apply()
}
