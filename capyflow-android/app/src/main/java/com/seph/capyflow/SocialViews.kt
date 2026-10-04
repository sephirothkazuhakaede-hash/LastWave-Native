package com.seph.capyflow

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import coil.compose.AsyncImage
import kotlinx.coroutines.*

@Composable fun liveProfile(social:SocialModel,id:String?,fallback:Profile?=null):Profile? {
    var person by remember(id){mutableStateOf(fallback)}
    DisposableEffect(social,id){val listener=id?.let{social.watchProfile(it){person=it}};onDispose{listener?.remove()}}
    return person
}
@Composable fun ProfileAvatar(profile:Profile?,size:Int){
    Box(Modifier.size(size.dp).clip(CircleShape).background(Violet.copy(alpha=.12f)),contentAlignment=Alignment.Center){
        if(profile?.avatarData!=null || !profile?.avatar.isNullOrBlank())AsyncImage(profile?.avatarData ?: profile?.avatar,null,modifier=Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
        else Icon(Icons.Default.Person,null,tint=Violet,modifier=Modifier.size((size*.55f).dp))
    }
}
@Composable fun ContactCard(social:SocialModel,id:String,onOpen:(Profile)->Unit,trailing:@Composable (Profile)->Unit = {}){
    val p=liveProfile(social,id) ?: return
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Glass).clickable{onOpen(p)}.padding(16.dp),verticalAlignment=Alignment.CenterVertically){
        ProfileAvatar(p,52);Column(Modifier.weight(1f).padding(horizontal=14.dp)){Text(p.displayName,fontSize=17.sp,fontWeight=FontWeight.Bold);Text("@${p.username}",fontSize=13.sp,color=Violet);if(p.bio.isNotBlank())Text(p.bio,fontSize=12.sp,maxLines=2,overflow=TextOverflow.Ellipsis,color=Color.White.copy(alpha=.6f))};trailing(p)
    }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun ProfilePreview(social:SocialModel,userID:String?,initial:Profile,onDismiss:()->Unit,onChat:(String)->Unit){
    var selectedID by remember(initial.id){mutableStateOf(initial.id)}
    var relationship by remember(selectedID){mutableStateOf<String?>(null)}
    var followers by remember(selectedID){mutableStateOf<List<String>>(emptyList())}
    var following by remember(selectedID){mutableStateOf<List<String>>(emptyList())}
    var editing by remember{mutableStateOf(false)}
    val p=liveProfile(social,selectedID,initial.takeIf{it.id==selectedID})
    DisposableEffect(selectedID){val a=social.watchRelationships(selectedID,true){followers=it};val b=social.watchRelationships(selectedID,false){following=it};onDispose{a?.remove();b?.remove()}}
    ModalBottomSheet(onDismissRequest=onDismiss,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night){
        BackHandler(relationship!=null){relationship=null}
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal=22.dp).navigationBarsPadding(),verticalArrangement=Arrangement.spacedBy(16.dp),contentPadding=PaddingValues(bottom=24.dp)){
            if(relationship!=null){
                item{Row(verticalAlignment=Alignment.CenterVertically){IconButton(onClick={relationship=null}){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Text(relationship!!,fontSize=26.sp,fontWeight=FontWeight.Bold)}}
                val people=if(relationship=="Followers")followers else following
                if(people.isEmpty())item{Text("No ${relationship!!.lowercase()} yet",color=Color.White.copy(alpha=.6f))}
                items(people,key={it}){id->ContactCard(social,id,{selectedID=it.id;relationship=null})}
            }else{
                item{Column(Modifier.fillMaxWidth(),horizontalAlignment=Alignment.CenterHorizontally){ProfileAvatar(p,96);Text(p?.displayName ?: "Loading profile…",fontSize=26.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(top=14.dp));p?.let{Text("@${it.username}",color=Violet);if(it.bio.isNotBlank())Text(it.bio,modifier=Modifier.padding(top=14.dp))}}}
                item{Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceEvenly){TextButton(onClick={relationship="Followers"}){Text("${followers.size} Followers")};TextButton(onClick={relationship="Following"}){Text("${following.size} Following")}}}
                p?.let{person->item{Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.Center){if(person.id==userID)Button(onClick={editing=true}){Text("Edit profile")}else{Button(onClick={social.follow(person,person.id !in social.following)}){Text(if(person.id in social.following)"Unfollow" else "Follow")};Spacer(Modifier.width(12.dp));OutlinedButton(onClick={onChat(person.id)}){Text("Message")}}}}
            }
        }
    }
    if(editing && p!=null) EditProfile(social,p){editing=false}
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun EditProfile(social:SocialModel,profile:Profile,onClose:()->Unit){
    var username by remember(profile.id){mutableStateOf(profile.username)};var name by remember(profile.id){mutableStateOf(profile.displayName)};var bio by remember(profile.id){mutableStateOf(profile.bio)};var photo by remember(profile.id){mutableStateOf<ByteArray?>(null)}
    val context=LocalContext.current;val scope=rememberCoroutineScope();var preparing by remember{mutableStateOf(false)}
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.GetContent()){uri->if(uri!=null)scope.launch{preparing=true;try{photo=withContext(Dispatchers.IO){context.contentResolver.openInputStream(uri)?.use{val image=android.graphics.BitmapFactory.decodeStream(it) ?: error("Choose an image");boundedJpeg(image)} ?: error("Couldn’t open photo")}}catch(e:Exception){social.error=e.message}finally{preparing=false}}}
    ModalBottomSheet(onDismissRequest=onClose,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night){Column(Modifier.fillMaxWidth().padding(24.dp).imePadding().navigationBarsPadding().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(14.dp)){
        Section("Edit profile");ProfileAvatar(profile.copy(avatarData=photo ?: profile.avatarData),88);TextButton(onClick={picker.launch("image/*")},enabled=!preparing){Text(if(preparing)"Preparing picture…" else "Change picture")}
        OutlinedTextField(username,{username=it},label={Text("Username")},prefix={Text("@")},singleLine=true,modifier=Modifier.fillMaxWidth());Text("Usernames can be changed once every 14 days. Your first custom username is free to choose.",fontSize=12.sp,color=Color.White.copy(alpha=.6f))
        OutlinedTextField(name,{if(it.length<=60)name=it},label={Text("Display name")},singleLine=true,modifier=Modifier.fillMaxWidth());OutlinedTextField(bio,{if(it.length<=160)bio=it},label={Text("Bio")},supportingText={Text("${bio.length}/160")},modifier=Modifier.fillMaxWidth())
        Button(onClick={social.saveProfile(username,name,bio,photo,onClose)},enabled=!social.savingProfile&&!preparing,modifier=Modifier.fillMaxWidth()){Text(if(social.savingProfile)"Saving…" else "Save profile")}
    }}
}
@Composable fun DrawerRow(title:String,icon:androidx.compose.ui.graphics.vector.ImageVector,onClick:()->Unit){
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Glass).border(1.dp,Color.White.copy(alpha=.07f),RoundedCornerShape(24.dp)).clickable(onClick=onClick).padding(20.dp),verticalAlignment=Alignment.CenterVertically){Icon(icon,null,tint=Violet);Text(title,fontWeight=FontWeight.SemiBold,modifier=Modifier.weight(1f).padding(start=16.dp));Icon(Icons.Default.ChevronRight,null,tint=Color.White.copy(alpha=.4f))}
}
@Composable fun AccountDrawer(vm:CapyModel,social:SocialModel,signIn:()->Unit,onClose:()->Unit,onProfile:(Profile)->Unit,onSocial:()->Unit){
    var page by remember{mutableStateOf("CapyFlow")};val scope=rememberCoroutineScope()
    BackHandler{if(page=="CapyFlow")onClose() else page="CapyFlow"}
    Column(Modifier.fillMaxHeight().fillMaxWidth(.88f).widthIn(max=420.dp).background(Night).statusBarsPadding().navigationBarsPadding().padding(18.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(14.dp)){
        Row(verticalAlignment=Alignment.CenterVertically){if(page!="CapyFlow")IconButton(onClick={page="CapyFlow"}){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Text(page,fontSize=26.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f));IconButton(onClick=onClose){Icon(Icons.Default.Close,"Close settings")}}
        when(page){
            "CapyFlow"->{
                val p=social.ownProfile
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(Violet.copy(alpha=.12f)).border(1.dp,Violet.copy(alpha=.25f),RoundedCornerShape(28.dp)).clickable{if(p!=null)onProfile(p) else signIn()}.padding(18.dp),verticalAlignment=Alignment.CenterVertically){ProfileAvatar(p,68);Column(Modifier.padding(start=16.dp)){Text(p?.displayName ?: "Welcome",fontSize=23.sp,fontWeight=FontWeight.Bold);Text(p?.let{"@${it.username}"} ?: "Sign in to CapyFlow",color=Color.White.copy(alpha=.6f));Text("View profile",color=Violet,modifier=Modifier.padding(top=5.dp))}}
                DrawerRow("Profile & friends",Icons.Default.People){onSocial()};DrawerRow("Messages",Icons.Default.Forum){onSocial()};DrawerRow("Settings",Icons.Default.Settings){page="Settings"};DrawerRow("Friend Activity privacy",Icons.Default.PrivacyTip){page="Friend Activity privacy"};DrawerRow("Updates",Icons.Default.SystemUpdate){page="Updates"}
                Section("Friend Activity")
                var now by remember{mutableLongStateOf(System.currentTimeMillis())};LaunchedEffect(Unit){while(true){delay(30000);now=System.currentTimeMillis()}}
                val active=social.activity.filterValues{it.expires>now && it.playing}
                if(active.isEmpty())Text("No friends listening right now",fontSize=13.sp,color=Color.White.copy(alpha=.55f))
                active.forEach{(id,a)->val friend=social.friends[id];Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).clickable{friend?.let(onProfile)}.padding(8.dp),verticalAlignment=Alignment.CenterVertically){ProfileAvatar(friend,48);Column(Modifier.weight(1f).padding(horizontal=12.dp)){Text(friend?.username ?: "Listener",fontWeight=FontWeight.Bold);Text(a.title,maxLines=2,overflow=TextOverflow.Ellipsis,fontSize=13.sp);Text(a.artist,color=Color.White.copy(alpha=.5f),fontSize=12.sp)};Artwork(a.artwork,42)}}
                Text("Your music and downloads work even when social features are offline.",fontSize=12.sp,color=Color.White.copy(alpha=.4f),modifier=Modifier.padding(top=12.dp))
            }
            "Settings"->{DrawerRow("Profile",Icons.Default.Person){social.ownProfile?.let(onProfile) ?: signIn()};DrawerRow("Streaming settings",Icons.Default.Cloud){page="Streaming settings"};DrawerRow("Audio quality",Icons.Default.GraphicEq){page="Audio quality"};if(vm.user!=null)TextButton(onClick={vm.signOut();onClose()}){Text("Sign out")}else Button(onClick=signIn){Text("Continue with Google")}}
            "Streaming settings"->StreamingSettings(vm)
            "Audio quality"->{Text("Applies to the next stream or download. Saved tracks retain their downloaded quality.",fontSize=13.sp,color=Color.White.copy(alpha=.6f));listOf("automatic" to "Best available","dataSaver" to "Data saver").forEach{(value,label)->Row(Modifier.fillMaxWidth().clickable{vm.saveQuality(value)}.padding(12.dp),verticalAlignment=Alignment.CenterVertically){RadioButton(vm.quality==value,{vm.saveQuality(value)});Text(label)}};Text(vm.audioDetails,fontSize=13.sp,color=Violet)}
            "Friend Activity privacy"->{Text("Share what you’re listening to with CapyFlow listeners on iOS and Android.");Row(verticalAlignment=Alignment.CenterVertically){Text("Share listening activity",modifier=Modifier.weight(1f));Switch(social.sharingActivity,{social.setActivitySharing(it)},enabled=vm.user!=null)};if(vm.user==null)Button(onClick=signIn){Text("Sign in")}}
            "Updates"->{Text("CapyFlow Android ${BuildConfig.VERSION_NAME}");Text("Install newer previews from the GitHub build artifacts.",color=Color.White.copy(alpha=.6f));val context=LocalContext.current;TextButton(onClick={context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,android.net.Uri.parse("https://github.com/sephirothkazuhakaede-hash/LastWave-Native/actions/workflows/capyflow-android.yml")))}){Text("Open builds")}}
        }
    }
}
@Composable fun StreamingSettings(vm:CapyModel){var address by remember(vm.server){mutableStateOf(vm.server)};Text(if(vm.automaticServer)"Automatic · follows your backend after restarts" else "Manual · uses the address you saved",fontSize=13.sp,color=Color.White.copy(alpha=.6f));OutlinedTextField(address,{address=it},label={Text("HTTPS server address")},singleLine=true,modifier=Modifier.fillMaxWidth());TextButton(onClick={vm.saveServer(address)}){Text("Save manual address")};TextButton(onClick={vm.useAutomaticServer()}){Text("Use automatic")};if(vm.serverStatus.isNotBlank())Text(vm.serverStatus,color=Violet,fontSize=12.sp)}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun CollaborateSheet(vm:CapyModel,social:SocialModel,playlist:Playlist,onClose:()->Unit,onProfile:(Profile)->Unit){
    var id by remember(playlist.id){mutableStateOf(social.sharedFor(playlist)?.id)};var invite by remember{mutableStateOf("")};var preparing by remember{mutableStateOf(false)};val scope=rememberCoroutineScope()
    val shared=social.sharedPlaylists.firstOrNull{it.id==id};val owner=shared==null || shared.ownerID==vm.user?.uid
    ModalBottomSheet(onDismissRequest=onClose,sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Night){LazyColumn(Modifier.fillMaxWidth().padding(horizontal=22.dp).navigationBarsPadding(),verticalArrangement=Arrangement.spacedBy(16.dp),contentPadding=PaddingValues(bottom=24.dp)){
        item{Text("Collaborate",fontSize=28.sp,fontWeight=FontWeight.Bold);Text(playlist.name,fontSize=18.sp,color=Violet,modifier=Modifier.padding(top=6.dp));Text("Invite people by their CapyFlow username. Everyone can add and remove songs; the owner manages people.",fontSize=13.sp,color=Color.White.copy(alpha=.6f),modifier=Modifier.padding(top=12.dp))}
        if(vm.user==null)item{Text("Sign in from Profile to create a shared playlist.")}
        else if(id==null)item{Button(onClick={preparing=true;scope.launch{try{id=social.publish(playlist)}catch(e:Exception){social.error=e.message}finally{preparing=false}}},enabled=!preparing){Text(if(preparing)"Creating…" else "Create shared playlist")}}
        else if(owner)item{OutlinedTextField(invite,{invite=it},label={Text("Invite @username")},singleLine=true,modifier=Modifier.fillMaxWidth());Button(onClick={id?.let{social.invite(it,invite)};invite=""},enabled=invite.isNotBlank(),modifier=Modifier.fillMaxWidth()){Icon(Icons.Default.PersonAdd,null);Text("Add collaborator",modifier=Modifier.padding(start=8.dp))}}
        item{Section("People")}
        items(shared?.memberIDs?.sortedBy{it!=shared.ownerID}.orEmpty(),key={it}){person->ContactCard(social,person,onProfile){if(person==shared?.ownerID)SuggestionChip(onClick={},label={Text("Owner")}) else if(owner)TextButton(onClick={shared?.let{social.removeMember(it,person)}}){Text("Remove")}}}
    }}
}
