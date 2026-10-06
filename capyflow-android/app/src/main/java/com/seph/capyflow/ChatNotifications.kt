package com.seph.capyflow

import android.content.Context
import androidx.compose.runtime.*
import com.google.firebase.firestore.*

object ChatPreferences {
    fun enabled(context:Context,key:String,default:Boolean=true)=context.getSharedPreferences("chat-notifications",Context.MODE_PRIVATE).getBoolean(key,default)
    fun set(context:Context,key:String,value:Boolean){context.getSharedPreferences("chat-notifications",Context.MODE_PRIVATE).edit().putBoolean(key,value).apply()}
}

@Composable fun GlobalChatAlerts(uid:String?,visible:Boolean,onNotice:(AppNotice)->Unit){
    val context=androidx.compose.ui.platform.LocalContext.current
    val currentVisible by rememberUpdatedState(visible)
    val callback by rememberUpdatedState(onNotice)
    DisposableEffect(uid){
        var baseline=false
        var seen:String?=null
        val listener=if(uid!=null && BuildConfig.FIREBASE_CONFIGURED) FirebaseFirestore.getInstance().collection("globalMessages").orderBy("createdAt",Query.Direction.DESCENDING).limit(1).addSnapshotListener(MetadataChanges.INCLUDE){snapshot,_->
            if(snapshot!=null && !snapshot.metadata.isFromCache && !snapshot.metadata.hasPendingWrites()){
                val doc=snapshot.documents.firstOrNull()
                if(baseline && doc!=null && doc.id!=seen && doc.getString("senderID")!=uid && !currentVisible && PushNotices.foreground && ChatPreferences.enabled(context,"globalBanners") && System.currentTimeMillis()-(doc.getTimestamp("createdAt")?.toDate()?.time ?: 0)<120000){
                    callback(AppNotice("Global Chat",doc.getString("text")?.take(300) ?: "New message",global=true))
                }
                seen=doc?.id;baseline=true
            }
        } else null
        onDispose{listener?.remove()}
    }
}
