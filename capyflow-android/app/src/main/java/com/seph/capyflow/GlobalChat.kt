package com.seph.capyflow

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.firebase.firestore.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.time.Instant
import java.time.ZoneId
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

fun chatDay(date:Long, zone:ZoneId=ZoneId.systemDefault()):LocalDate = Instant.ofEpochMilli(date).atZone(zone).toLocalDate()
fun chatDateLabel(date:Long, today:LocalDate=LocalDate.now()):String = when(val day=chatDay(date)) {
    today -> "Today"
    today.minusDays(1) -> "Yesterday"
    else -> day.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
}
fun chatTime(date:Long):String = Instant.ofEpochMilli(date).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

class GlobalChatModel:ViewModel() {
    var messages by mutableStateOf<List<Message>>(emptyList()); private set
    var profiles by mutableStateOf<Map<String,Profile>>(emptyMap()); private set
    var activeUserIDs by mutableStateOf<List<String>>(emptyList()); private set
    var loading by mutableStateOf(false); private set
    var sending by mutableStateOf(false); private set
    var loadingOlder by mutableStateOf(false); private set
    var hasMore by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    private var database:FirebaseFirestore?=null
    private var uid:String?=null
    private var listener:ListenerRegistration?=null
    private var presenceListener:ListenerRegistration?=null
    private var presenceJob:kotlinx.coroutines.Job?=null
    private var generation=0
    private var oldest:DocumentSnapshot?=null
    private val history=mutableMapOf<String,Message>()
    private val requestedProfiles=mutableSetOf<String>()
    private var lastSent=0L
    fun start(db:FirebaseFirestore?,userID:String?,known:Map<String,Profile> = emptyMap()) {
        val retained=if(uid==userID)profiles else emptyMap()
        stop();database=db;uid=userID;messages=emptyList();profiles=retained+known;history.clear();requestedProfiles.clear();oldest=null;hasMore=false;error=null
        loading=db!=null && userID!=null
        if(db==null || userID==null)return
        val epoch=generation
        listener=db.collection("globalMessages").orderBy("createdAt",Query.Direction.DESCENDING).limit(50).addSnapshotListener(MetadataChanges.INCLUDE){snapshot,failure ->
            if(epoch!=generation)return@addSnapshotListener
            loading=false
            if(failure!=null){error="Global Chat couldn’t connect. Please try again.";return@addSnapshotListener}
            if(snapshot!=null){error=null;merge(snapshot.documents,epoch);if(oldest==null){oldest=snapshot.documents.lastOrNull();hasMore=snapshot.size()==50}}
        }
    }
    fun startPresence() {
    val db=database ?: return
    val userID=uid ?: return

    stopPresence(remove=false)
    val epoch=generation

    presenceListener=db.collection("globalChatPresence")
        .addSnapshotListener { snapshot,_ ->
            if(epoch!=generation || snapshot==null)return@addSnapshotListener

            val cutoff=System.currentTimeMillis()-75_000L

            activeUserIDs=snapshot.documents.mapNotNull { document ->
                val presenceUID=document.getString("uid")
                val updated=document.getTimestamp("updatedAt")?.toDate()?.time

                if(presenceUID!=null && updated!=null && updated>=cutoff)
                    presenceUID
                else null
            }.distinct().sorted()

            loadPresenceProfiles(activeUserIDs,epoch)
        }

    presenceJob=viewModelScope.launch {
        while(true) {
            try {
                db.collection("globalChatPresence")
                    .document(userID)
                    .set(
                        mapOf(
                            "uid" to userID,
                            "updatedAt" to FieldValue.serverTimestamp()
                        )
                    ).await()
            } catch(_:Exception) {
                // Presence must never interrupt Global Chat.
            }

            kotlinx.coroutines.delay(25_000L)

            if(epoch!=generation)return@launch
        }
    }
}

fun stopPresence(remove:Boolean=true) {
    val db=database
    val userID=uid

    presenceListener?.remove()
    presenceListener=null

    presenceJob?.cancel()
    presenceJob=null

    activeUserIDs=emptyList()

    if(remove && db!=null && userID!=null) {
        viewModelScope.launch {
            try {
                db.collection("globalChatPresence")
                    .document(userID)
                    .delete()
                    .await()
            } catch(_:Exception) {
                // Best-effort cleanup.
            }
        }
    }
}

private fun loadPresenceProfiles(ids:List<String>,epoch:Int) {
    val db=database ?: return
    val missing=ids.filter { profiles[it]==null }

    if(missing.isEmpty())return

    viewModelScope.launch {
        for(chunk in missing.chunked(20)) {
            try {
                val result=db.collection("profiles")
                    .whereIn(FieldPath.documentId(),chunk)
                    .limit(20)
                    .get()
                    .await()

                if(epoch!=generation)return@launch

                profiles=profiles+result.documents.map {
                    it.id to Profile.from(it)
                }
            } catch(_:Exception) {
                // Profile failure must not break presence or chat.
            }
        }
    }
}
    fun seed(known:Map<String,Profile>){profiles=profiles+known}
    fun stop(){
    stopPresence()
    generation++
    listener?.remove()
    listener=null
    sending=false
    loadingOlder=false
}
    override fun onCleared(){stop()}
    private fun merge(docs:List<DocumentSnapshot>,epoch:Int) {
        docs.forEach{d -> val sender=d.getString("senderID");val text=d.getString("text");if(sender!=null && text!=null)history[d.id]=Message(d.id,sender,text,d.metadata.hasPendingWrites(),d.getTimestamp("createdAt",DocumentSnapshot.ServerTimestampBehavior.ESTIMATE)?.toDate()?.time ?: System.currentTimeMillis())}
        messages=history.values.sortedWith(compareBy<Message>{it.date}.thenBy{it.id}).takeLast(500)
        history.keys.retainAll(messages.map{it.id}.toSet())
        if(messages.size>=500)hasMore=false
        val missing=messages.map{it.sender}.toSet()-requestedProfiles
        requestedProfiles.addAll(missing)
        viewModelScope.launch{
            for(ids in missing.chunked(20))try{
                val query=database?.collection("profiles")?.whereIn(FieldPath.documentId(),ids)?.limit(20) ?: return@launch
                val cached=try{query.get(Source.CACHE).await()}catch(_:Exception){null}
                if(epoch!=generation)return@launch
                cached?.let{profiles=it.documents.associate{d->d.id to Profile.from(d)}+profiles}
                val result=query.get(Source.SERVER).await()
                if(epoch!=generation)return@launch
                profiles=profiles+result.documents.map{it.id to Profile.from(it)}
            }catch(e:Exception){if(epoch==generation){requestedProfiles.removeAll(ids.toSet());error="Some profiles couldn’t load. Please try again."}}
        }
    }
    fun loadOlder(){val cursor=oldest ?: return;val db=database ?: return;if(loadingOlder || !hasMore)return
        loadingOlder=true;val epoch=generation
        viewModelScope.launch{try{val result=db.collection("globalMessages").orderBy("createdAt",Query.Direction.DESCENDING).startAfter(cursor).limit(50).get().await()
            if(epoch==generation){merge(result.documents,epoch);oldest=result.documents.lastOrNull();hasMore=result.size()==50 && messages.size<500}
        }catch(e:Exception){if(epoch==generation)error="Older messages couldn’t load. Please try again."}finally{if(epoch==generation)loadingOlder=false}}
    }
    fun send(raw:String,onSent:()->Unit){val db=database ?: return;val sender=uid ?: return;val text=raw.trim();if(sending || text.isBlank() || text.length>4000)return
        if(System.currentTimeMillis()-lastSent<2000){error="Give it a moment before sending another message.";return}
        sending=true;error=null;val epoch=generation;val ref=db.collection("globalMessages").document();val batch=db.batch();val time=FieldValue.serverTimestamp()
        batch.set(ref,mapOf("senderID" to sender,"text" to text,"createdAt" to time))
        batch.set(db.collection("globalChatSenders").document(sender),mapOf("lastSentAt" to time,"messageID" to ref.id))
        viewModelScope.launch{try{batch.commit().await();if(epoch==generation){lastSent=System.currentTimeMillis();onSent()}}catch(e:Exception){if(epoch==generation)error="Message wasn’t sent. Wait a moment and try again."}finally{if(epoch==generation)sending=false}}
    }
}

@Composable fun GlobalChatScreen(vm:CapyModel,social:SocialModel,signIn:()->Unit,onProfile:(Profile)->Unit,onClose:()->Unit){
    val chat:GlobalChatModel=viewModel();var draft by remember{mutableStateOf("")};val list=rememberLazyListState();var chatPlayerOpen by remember{mutableStateOf(false)}
    val lifecycleOwner=LocalLifecycleOwner.current
    val known=social.friends + listOfNotNull(social.ownProfile).associateBy{it.id}
    LaunchedEffect(known){chat.seed(known)}
    DisposableEffect(vm.user?.uid,lifecycleOwner){
    chat.start(vm.db,vm.user?.uid,known)

    val observer=LifecycleEventObserver{_,event ->
        when(event){
            Lifecycle.Event.ON_START -> chat.startPresence()
            Lifecycle.Event.ON_STOP -> chat.stopPresence()
            else -> Unit
        }
    }

    lifecycleOwner.lifecycle.addObserver(observer)

    if(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)){
        chat.startPresence()
    }

    onDispose{
        lifecycleOwner.lifecycle.removeObserver(observer)
        chat.stop()
    }
}
    
    BackHandler(onBack=onClose)
    LaunchedEffect(chat.messages.lastOrNull()?.id){if(list.firstVisibleItemIndex<=1)list.animateScrollToItem(0)}
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().padding(16.dp)){
        Row(verticalAlignment=Alignment.CenterVertically){IconButton(onClick=onClose){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Text("Global Chat",fontSize=20.sp,fontWeight=FontWeight.Bold)}
        if(vm.user==null){Text("Sign in to chat with CapyFlow listeners.");Button(onClick=signIn){Text("Continue with Google")};Spacer(Modifier.weight(1f))}
        else {
            if(chat.activeUserIDs.isNotEmpty()){
        GlobalChatPresenceStrip(
        userIDs=chat.activeUserIDs,
        profiles=chat.profiles,
        onProfile=onProfile
    )
    Spacer(Modifier.height(8.dp))
}
            if(chat.loading)LinearProgressIndicator(Modifier.fillMaxWidth(),color=Violet)
            LazyColumn(Modifier.weight(1f).fillMaxWidth(),state=list,reverseLayout=true,verticalArrangement=Arrangement.spacedBy(0.dp),contentPadding=PaddingValues(vertical=12.dp)){
                val ordered=chat.messages.reversed()
                if(ordered.isEmpty() && !chat.loading && chat.error==null)item{Text("Say hello to the CapyFlow community.",color=Color.White.copy(alpha=.6f))}
                itemsIndexed(ordered,key={_,m->m.id}){index,m ->
                    Column{
                        if(index==ordered.lastIndex || chatDay(m.date)!=chatDay(ordered[index+1].date))Text(chatDateLabel(m.date),fontSize=12.sp,color=Color.White.copy(alpha=.55f),modifier=Modifier.fillMaxWidth().padding(vertical=10.dp))
                        GlobalMessageRow(m,chat.profiles[m.sender],m.sender==vm.user?.uid,onProfile,previousSame=index+1<ordered.size && ordered[index+1].sender==m.sender && chatDay(ordered[index+1].date)==chatDay(m.date),nextSame=index>0 && ordered[index-1].sender==m.sender && chatDay(ordered[index-1].date)==chatDay(m.date))
                    }
                }
                if(chat.hasMore)item{TextButton(onClick={chat.loadOlder()},enabled=!chat.loadingOlder){Text(if(chat.loadingOlder)"Loading…" else "Load older messages")}}
            }
        }
        chat.error?.let{Text(it,color=Violet,fontSize=12.sp);TextButton(onClick={chat.start(vm.db,vm.user?.uid,known)}){Text("Reconnect")}}
        Column(Modifier.fillMaxWidth().padding(top=10.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            vm.current?.let{ChatMiniPlayer(it,vm){chatPlayerOpen=true}}
            if(vm.user!=null)Row(verticalAlignment=Alignment.Bottom){TextField(draft,{if(it.length<=4000)draft=it},placeholder={Text("Message")},modifier=Modifier.weight(1f),shape=RoundedCornerShape(24.dp),colors=TextFieldDefaults.colors(focusedContainerColor=Raised,unfocusedContainerColor=Raised,focusedIndicatorColor=Color.Transparent,unfocusedIndicatorColor=Color.Transparent),maxLines=5);Spacer(Modifier.width(8.dp));FilledIconButton(onClick={val submitted=draft;chat.send(submitted){if(draft==submitted)draft=""}},enabled=draft.isNotBlank()&&!chat.sending&&social.ownProfile!=null){Icon(Icons.AutoMirrored.Filled.Send,"Send message",tint=Night)}}
        }
    }
    if(chatPlayerOpen){
        BackHandler{chatPlayerOpen=false}
        PlayerScreen(vm,{chatPlayerOpen=false},{},{})
    }
}

@Composable private fun GlobalMessageRow(message:Message,person:Profile?,own:Boolean,onProfile:(Profile)->Unit,previousSame:Boolean,nextSame:Boolean){
    BoxWithConstraints(Modifier.fillMaxWidth().padding(top=if(previousSame)2.dp else 8.dp)){
        Row(Modifier.align(if(own)Alignment.CenterEnd else Alignment.CenterStart),verticalAlignment=Alignment.Bottom,horizontalArrangement=Arrangement.spacedBy(7.dp)){
            if(!own){if(!nextSame)Box(Modifier.clickable(enabled=person!=null){person?.let(onProfile)}){ProfileAvatar(person,30)} else Spacer(Modifier.width(30.dp))}
            Column(horizontalAlignment=if(own)Alignment.End else Alignment.Start){
                if(!previousSame && person!=null)Text(person.displayName,color=Violet,fontSize=12.sp,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis)
                Surface(shape=RoundedCornerShape(if(previousSame||nextSame)13.dp else 19.dp),color=if(own)Violet else Raised,modifier=Modifier.padding(top=if(!previousSame && person!=null)3.dp else 0.dp)){
                    Text(message.text,color=if(own)Night else Color.White,modifier=Modifier.widthIn(max=minOf(280.dp,maxWidth-37.dp)).padding(horizontal=13.dp,vertical=9.dp))
                }
                Text(if(message.pending)"Sending…" else chatTime(message.date),fontSize=10.sp,color=Color.White.copy(alpha=.5f),modifier=Modifier.padding(top=2.dp))
            }
            if(own){if(!nextSame)Box(Modifier.clickable(enabled=person!=null){person?.let(onProfile)}){ProfileAvatar(person,30)} else Spacer(Modifier.width(30.dp))}
        }
    }
}


@Composable
private fun GlobalChatPresenceStrip(
    userIDs:List<String>,
    profiles:Map<String,Profile>,
    onProfile:(Profile)->Unit
){
    var showUsers by remember{mutableStateOf(false)}
    val visible=userIDs.take(4)

    Surface(
        shape=RoundedCornerShape(16.dp),
        color=Raised,
        modifier=Modifier
            .fillMaxWidth()
            .clickable{showUsers=true}
    ){
        Row(
            modifier=Modifier.padding(horizontal=12.dp,vertical=9.dp),
            verticalAlignment=Alignment.CenterVertically
        ){
            Box(
                modifier=Modifier.width(
                    if(visible.isEmpty()) 0.dp
                    else 28.dp + ((visible.size-1)*20).dp
                )
            ){
                visible.forEachIndexed{index,userID ->
                    Box(
                        modifier=Modifier
                            .offset(x=(index*20).dp)
                            .size(28.dp)
                    ){
                        ProfileAvatar(profiles[userID],28)
                    }
                }
            }

            Spacer(Modifier.width(10.dp))

            Text(
                "In chat · ${userIDs.size}",
                color=Color.White,
                fontSize=14.sp,
                fontWeight=FontWeight.SemiBold
            )

            if(userIDs.size>4){
                Spacer(Modifier.width(6.dp))
                Text(
                    "+${userIDs.size-4}",
                    color=Color.White.copy(alpha=.6f),
                    fontSize=12.sp
                )
            }

            Spacer(Modifier.weight(1f))

            Text(
                "›",
                color=Color.White.copy(alpha=.45f),
                fontSize=22.sp
            )
        }
    }

    if(showUsers){
        AlertDialog(
            onDismissRequest={showUsers=false},
            title={
                Text(
                    "In chat · ${userIDs.size}",
                    color=Color.White
                )
            },
            text={
                LazyColumn(
                    modifier=Modifier
                        .fillMaxWidth()
                        .heightIn(max=420.dp),
                    verticalArrangement=Arrangement.spacedBy(8.dp)
                ){
                    items(userIDs,key={it}){userID ->
                        val person=profiles[userID]

                        Row(
                            modifier=Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .clickable(enabled=person!=null){
                                    if(person!=null){
                                        showUsers=false
                                        onProfile(person)
                                    }
                                }
                                .padding(10.dp),
                            verticalAlignment=Alignment.CenterVertically
                        ){
                            ProfileAvatar(person,42)

                            Spacer(Modifier.width(12.dp))

                            Column(Modifier.weight(1f)){
                                Text(
                                    person?.displayName ?: "Loading profile…",
                                    color=Color.White,
                                    fontWeight=FontWeight.SemiBold,
                                    maxLines=1,
                                    overflow=TextOverflow.Ellipsis
                                )

                                if(person!=null){
                                    Text(
                                        "@${person.username}",
                                        color=Color.White.copy(alpha=.55f),
                                        fontSize=12.sp,
                                        maxLines=1,
                                        overflow=TextOverflow.Ellipsis
                                    )
                                }
                            }

                            Box(
                                Modifier
                                    .size(8.dp)
                                    .clip(androidx.compose.foundation.shape.CircleShape)
                                    .background(Color.Green)
                            )
                        }
                    }
                }
            },
            confirmButton={
                TextButton(onClick={showUsers=false}){
                    Text("Close",color=Violet)
                }
            },
            containerColor=Night
        )
    }
}
