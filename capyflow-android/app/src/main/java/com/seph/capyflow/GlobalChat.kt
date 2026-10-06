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
    var loading by mutableStateOf(false); private set
    var sending by mutableStateOf(false); private set
    var loadingOlder by mutableStateOf(false); private set
    var hasMore by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    private var database:FirebaseFirestore?=null
    private var uid:String?=null
    private var listener:ListenerRegistration?=null
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
    fun seed(known:Map<String,Profile>){profiles=profiles+known}
    fun stop(){generation++;listener?.remove();listener=null;sending=false;loadingOlder=false}
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
    val chat:GlobalChatModel=viewModel();var draft by remember{mutableStateOf("")};val list=rememberLazyListState()
    val known=social.friends + listOfNotNull(social.ownProfile).associateBy{it.id}
    LaunchedEffect(known){chat.seed(known)}
    DisposableEffect(vm.user?.uid){chat.start(vm.db,vm.user?.uid,known);onDispose{chat.stop()}}
    BackHandler(onBack=onClose)
    LaunchedEffect(chat.messages.lastOrNull()?.id){if(list.firstVisibleItemIndex==0)list.animateScrollToItem(0)}
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding().padding(16.dp)){
        Row(verticalAlignment=Alignment.CenterVertically){IconButton(onClick=onClose){Icon(Icons.AutoMirrored.Filled.ArrowBack,"Back")};Text("Global Chat",fontSize=20.sp,fontWeight=FontWeight.Bold)}
        if(vm.user==null){Text("Sign in to chat with CapyFlow listeners.");Button(onClick=signIn){Text("Continue with Google")};Spacer(Modifier.weight(1f))}
        else {
            if(chat.loading)LinearProgressIndicator(Modifier.fillMaxWidth(),color=Violet)
            LazyColumn(Modifier.weight(1f).fillMaxWidth(),state=list,reverseLayout=true,verticalArrangement=Arrangement.spacedBy(14.dp),contentPadding=PaddingValues(vertical=12.dp)){
                val ordered=chat.messages.reversed()
                if(ordered.isEmpty() && !chat.loading && chat.error==null)item{Text("Say hello to the CapyFlow community.",color=Color.White.copy(alpha=.6f))}
                itemsIndexed(ordered,key={_,m->m.id}){index,m ->
                    Column{
                        if(index==ordered.lastIndex || chatDay(m.date)!=chatDay(ordered[index+1].date))Text(chatDateLabel(m.date),fontSize=12.sp,color=Color.White.copy(alpha=.55f),modifier=Modifier.fillMaxWidth().padding(vertical=10.dp))
                        GlobalMessageRow(m,chat.profiles[m.sender],m.sender==vm.user?.uid,onProfile)
                    }
                }
                if(chat.hasMore)item{TextButton(onClick={chat.loadOlder()},enabled=!chat.loadingOlder){Text(if(chat.loadingOlder)"Loading…" else "Load older messages")}}
            }
        }
        chat.error?.let{Text(it,color=Violet,fontSize=12.sp);TextButton(onClick={chat.start(vm.db,vm.user?.uid,known)}){Text("Reconnect")}}
        if(vm.user!=null)Row(verticalAlignment=Alignment.Bottom){TextField(draft,{if(it.length<=4000)draft=it},placeholder={Text("Message")},modifier=Modifier.weight(1f),shape=RoundedCornerShape(24.dp),colors=TextFieldDefaults.colors(focusedContainerColor=Raised,unfocusedContainerColor=Raised,focusedIndicatorColor=Color.Transparent,unfocusedIndicatorColor=Color.Transparent),maxLines=5);Spacer(Modifier.width(8.dp));FilledIconButton(onClick={val submitted=draft;chat.send(submitted){if(draft==submitted)draft=""}},enabled=draft.isNotBlank()&&!chat.sending&&social.ownProfile!=null){Icon(Icons.AutoMirrored.Filled.Send,"Send message",tint=Night)}}
    }
}

@Composable private fun GlobalMessageRow(message:Message,person:Profile?,own:Boolean,onProfile:(Profile)->Unit){
    BoxWithConstraints(Modifier.fillMaxWidth()){
        Row(Modifier.align(if(own)Alignment.CenterEnd else Alignment.CenterStart).widthIn(max=maxWidth*.86f),verticalAlignment=Alignment.Top,horizontalArrangement=Arrangement.spacedBy(8.dp)){
            if(!own)Box(Modifier.clickable(enabled=person!=null){person?.let(onProfile)}){ProfileAvatar(person,32)}
            Column(Modifier.weight(1f,false),horizontalAlignment=if(own)Alignment.End else Alignment.Start){
                if(person!=null)Text(person.displayName,color=Violet,fontSize=12.sp,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis)
                else Box(Modifier.padding(vertical=4.dp).size(96.dp,12.dp).clip(RoundedCornerShape(6.dp)).background(Color.White.copy(alpha=.1f)))
                Surface(shape=RoundedCornerShape(18.dp),color=if(own)Violet else Raised,modifier=Modifier.padding(top=4.dp)){
                    Column(Modifier.padding(horizontal=13.dp,vertical=10.dp)){
                        Text(message.text,color=if(own)Night else Color.White)
                        Text(if(message.pending)"Sending…" else chatTime(message.date),fontSize=10.sp,color=(if(own)Night else Color.White).copy(alpha=.6f),modifier=Modifier.align(Alignment.End).padding(top=4.dp))
                    }
                }
            }
            if(own)Box(Modifier.clickable(enabled=person!=null){person?.let(onProfile)}){ProfileAvatar(person,32)}
        }
    }
}
