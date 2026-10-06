package com.seph.capyflow

import android.content.Context
import androidx.compose.runtime.*
import com.google.firebase.firestore.*
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import com.google.firebase.auth.FirebaseAuth

object ChatPreferences {
    fun enabled(context:Context,key:String,default:Boolean=true)=context.getSharedPreferences("chat-notifications",Context.MODE_PRIVATE).getBoolean(key,default)
    fun set(context:Context,key:String,value:Boolean){context.getSharedPreferences("chat-notifications",Context.MODE_PRIVATE).edit().putBoolean(key,value).apply()}
}

@Composable fun GlobalChatAlerts(uid:String?,visible:Boolean,onNotice:(AppNotice)->Unit){
    val context=androidx.compose.ui.platform.LocalContext.current
    val currentVisible by rememberUpdatedState(visible)
    val callback by rememberUpdatedState(onNotice)
    val scope=rememberCoroutineScope()
    DisposableEffect(uid){
        var active=true
        var baseline=false
        var seen:String?=null
        val listener=if(uid!=null && BuildConfig.FIREBASE_CONFIGURED) FirebaseFirestore.getInstance().collection("globalMessages").orderBy("createdAt",Query.Direction.DESCENDING).limit(1).addSnapshotListener(MetadataChanges.INCLUDE){snapshot,_->
            if(snapshot!=null && !snapshot.metadata.isFromCache && !snapshot.metadata.hasPendingWrites()){
                val doc=snapshot.documents.firstOrNull()
                if(baseline && doc!=null && doc.id!=seen && doc.getString("senderID")!=uid && !currentVisible && PushNotices.foreground && ChatPreferences.enabled(context,"globalBanners") && System.currentTimeMillis()-(doc.getTimestamp("createdAt")?.toDate()?.time ?: 0)<120000){
                    val messageID=doc.id
                    val sender=doc.getString("senderID")
                    scope.launch {
                        val person=try{sender?.let{FirebaseFirestore.getInstance().collection("profiles").document(it).get().await() }?.takeIf{it.exists()}?.let{Profile.from(it)}}catch(_:Exception){null}
                        if(active && seen==messageID && FirebaseAuth.getInstance().currentUser?.uid==uid && !currentVisible && PushNotices.foreground && ChatPreferences.enabled(context,"globalBanners"))
                            callback(AppNotice("Global Chat",doc.getString("text")?.take(300) ?: "New message",global=true,profile=person))
                    }
                }
                seen=doc?.id;baseline=true
            }
        } else null
        onDispose{active=false;listener?.remove()}
    }
}
