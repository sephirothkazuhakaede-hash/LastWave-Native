package com.seph.capyflow

import androidx.compose.runtime.*
import kotlinx.coroutines.tasks.await
import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.flow.MutableSharedFlow
import java.util.UUID

object PushNotices {
    val events=MutableSharedFlow<AppNotice>(extraBufferCapacity=16)
    @Volatile var foreground=false
    @Volatile var activePeer:String?=null
}
object PushRegistry {
    private var registeredUID:String?=null
    private var generation=0
    var registered by mutableStateOf(false);private set
    var registering by mutableStateOf(false);private set
    fun allowed(context:Context):Boolean {
        if(!androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled())return false
        val channel=context.getSystemService(NotificationManager::class.java).getNotificationChannel("messages")
        return channel==null || channel.importance!=NotificationManager.IMPORTANCE_NONE
    }
    var status by mutableStateOf("Sign in to receive message notifications.");private set
    suspend fun unregister(context:Context,uid:String){
        generation++;registeredUID=null;registered=false;registering=false
        status="Sign in to receive message notifications."
        val device=context.getSharedPreferences("capyflow-push",Context.MODE_PRIVATE).getString("deviceID",null) ?: return
        FirebaseFirestore.getInstance().collection("globalPushDevices").document(device).delete().await()
        FirebaseFirestore.getInstance().collection("users").document(uid).collection("devices").document(device).delete().await()
        status="Sign in to receive message notifications."
    }
    fun bind(context:Context,uid:String?){
        val epoch=++generation;registered=false;registering=false
        if(!BuildConfig.FIREBASE_CONFIGURED){status="Message notifications are temporarily unavailable.";return}
        val prefs=context.getSharedPreferences("capyflow-push",Context.MODE_PRIVATE)
        var device=prefs.getString("deviceID",null) ?: UUID.randomUUID().toString().also{prefs.edit().putString("deviceID",it).apply()}
        val previous=prefs.getString("ownerUID",null) ?: registeredUID
        val previousDevice=device
        if(previous!=null && previous!=uid)FirebaseFirestore.getInstance().collection("users").document(previous).collection("devices").document(previousDevice).delete()
        if(previous!=null && previous!=uid){
            FirebaseFirestore.getInstance().collection("globalPushDevices").document(previousDevice).delete()
            device=UUID.randomUUID().toString();prefs.edit().putString("deviceID",device).apply()
        }
        prefs.edit().putString("ownerUID",uid).apply()
        registeredUID=uid
        if(uid==null){status="Sign in to receive message notifications.";return}
        if(!ChatPreferences.enabled(context,"globalPush",false))FirebaseFirestore.getInstance().collection("globalPushDevices").document(device).delete()
        if(!allowed(context)){status="Allow notifications to receive messages in the background.";return}
        registering=true
        status="Turning on message notifications…"
        FirebaseMessaging.getInstance().token.addOnSuccessListener{token->if(FirebaseAuth.getInstance().currentUser?.uid==uid && registeredUID==uid && epoch==generation){
            val db=FirebaseFirestore.getInstance()

// DM push registration is independent from Global Chat push.
db.collection("users")
    .document(uid)
    .collection("devices")
    .document(device)
    .set(
        mapOf(
            "token" to token,
            "platform" to "android",
            "updatedAt" to FieldValue.serverTimestamp()
        )
    )
    .addOnSuccessListener{
        if(registeredUID==uid && epoch==generation){
            registered=true
            registering=false
            status="Ready to receive message notifications."
        }
    }
    .addOnFailureListener{
        if(registeredUID==uid && epoch==generation){
            registered=false
            registering=false
            status="Couldn’t enable message notifications. Please try again."
        }
    }

// Global Chat push is optional and must never break DM push registration.
if(ChatPreferences.enabled(context,"globalPush",false)){
    db.collection("globalPushDevices")
        .document(device)
        .set(
            mapOf(
                "uid" to uid,
                "token" to token,
                "platform" to "android",
                "updatedAt" to FieldValue.serverTimestamp()
            )
        )
        .addOnFailureListener{
            // Best-effort only. DM push remains registered.
        }
}else{
    db.collection("globalPushDevices")
        .document(device)
        .delete()
}
        }}.addOnFailureListener{if(registeredUID==uid && epoch==generation){registered=false;registering=false;status="Couldn’t enable notifications. Check your connection and try again."}}
    }
}
class CapyMessagingService:FirebaseMessagingService(){
    override fun onNewToken(token:String){PushRegistry.bind(this,FirebaseAuth.getInstance().currentUser?.uid)}
    override fun onMessageReceived(message:RemoteMessage){
        val uid=FirebaseAuth.getInstance().currentUser?.uid ?: return
        val global=message.data["kind"]=="global"
        if(!global && message.data["recipientID"]!=uid)return
        if(global && !ChatPreferences.enabled(this,"globalPush",false))return
        val peer=message.data["senderID"] ?: return
        if(peer==uid || (!global && PushNotices.foreground && PushNotices.activePeer==peer))return
        val title=message.data["title"]?.take(120) ?: "New message"
        val body=message.data["body"]?.take(300) ?: "Open CapyFlow to read it."
        val deliveredID=message.data["messageID"]
        if(!global && !PushNotices.foreground && deliveredID!=null && deliveredID.length<=128){
            FirebaseFirestore.getInstance().collection("conversations").document(SocialModel.conversationID(uid,peer)).collection("receipts").document(uid)
                .set(mapOf("messageID" to deliveredID,"receivedAt" to FieldValue.serverTimestamp()))
                .addOnFailureListener { /* A newer message may supersede this receipt; the inbox catches up on resume. */ }
        }
        if(PushNotices.foreground)return // The live inbox listener supplies foreground banners.
        if(Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(this,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)return
        val manager=getSystemService(NotificationManager::class.java)
        val channel=if(global)"global-chat" else "messages"
        manager.createNotificationChannel(NotificationChannel(channel,if(global)"Global Chat" else "Messages",NotificationManager.IMPORTANCE_HIGH).apply{description="Messages from CapyFlow listeners"})
        val intent=Intent(this,MainActivity::class.java).putExtra("chatPeer",if(global)"global-chat" else peer).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending=PendingIntent.getActivity(this,(if(global)"global-chat" else peer).hashCode(),intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val generic=NotificationCompat.Builder(this,channel).setSmallIcon(R.drawable.ic_notification_capyflow).setContentTitle("CapyFlow").setContentText("New message").build()
        val notification=NotificationCompat.Builder(this,channel).setSmallIcon(R.drawable.ic_notification_capyflow).setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(pending).setAutoCancel(true).setCategory(NotificationCompat.CATEGORY_MESSAGE).setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(generic).build()
        manager.notify((if(global)"global-chat" else peer).hashCode(),notification)
    }
}
