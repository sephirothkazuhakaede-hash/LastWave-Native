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
    var status by mutableStateOf("Sign in to register this device for messages.");private set
    suspend fun unregister(context:Context,uid:String){
        registeredUID=null
        val device=context.getSharedPreferences("capyflow-push",Context.MODE_PRIVATE).getString("deviceID",null) ?: return
        FirebaseFirestore.getInstance().collection("users").document(uid).collection("devices").document(device).delete().await()
        status="Sign in to register this device for messages."
    }
    fun bind(context:Context,uid:String?){
        if(!BuildConfig.FIREBASE_CONFIGURED){status="Notifications aren’t connected in this build.";return}
        val prefs=context.getSharedPreferences("capyflow-push",Context.MODE_PRIVATE)
        val device=prefs.getString("deviceID",null) ?: UUID.randomUUID().toString().also{prefs.edit().putString("deviceID",it).apply()}
        val previous=registeredUID
        if(previous!=null && previous!=uid)FirebaseFirestore.getInstance().collection("users").document(previous).collection("devices").document(device).delete()
        registeredUID=uid
        if(uid==null){status="Sign in to register this device for messages.";return}
        if(Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(context,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED){status="Allow notifications to receive messages in the background.";return}
        status="Registering this device…"
        FirebaseMessaging.getInstance().token.addOnSuccessListener{token->if(FirebaseAuth.getInstance().currentUser?.uid==uid && registeredUID==uid){
            FirebaseFirestore.getInstance().collection("users").document(uid).collection("devices").document(device).set(mapOf("token" to token,"platform" to "android","updatedAt" to FieldValue.serverTimestamp()))
                .addOnSuccessListener{if(registeredUID==uid)status="This device is registered for message notifications."}
                .addOnFailureListener{if(registeredUID==uid)status="Device registration failed: ${it.message}"}
        }}.addOnFailureListener{if(registeredUID==uid)status="Couldn’t obtain a notification token: ${it.message}"}
    }
}
class CapyMessagingService:FirebaseMessagingService(){
    override fun onNewToken(token:String){PushRegistry.bind(this,FirebaseAuth.getInstance().currentUser?.uid)}
    override fun onMessageReceived(message:RemoteMessage){
        val uid=FirebaseAuth.getInstance().currentUser?.uid ?: return
        if(message.data["recipientID"]!=uid)return
        val peer=message.data["senderID"] ?: return
        if(peer==uid || (PushNotices.foreground && PushNotices.activePeer==peer))return
        val title=message.data["title"]?.take(120) ?: "New message"
        val body=message.data["body"]?.take(300) ?: "Open CapyFlow to read it."
        if(PushNotices.foreground)return // The live inbox listener supplies foreground banners.
        if(Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(this,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)return
        val manager=getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("messages","Messages",NotificationManager.IMPORTANCE_HIGH).apply{description="Messages from CapyFlow listeners"})
        val intent=Intent(this,MainActivity::class.java).putExtra("chatPeer",peer).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending=PendingIntent.getActivity(this,peer.hashCode(),intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val generic=NotificationCompat.Builder(this,"messages").setSmallIcon(android.R.drawable.ic_dialog_email).setContentTitle("CapyFlow").setContentText("New message").build()
        val notification=NotificationCompat.Builder(this,"messages").setSmallIcon(android.R.drawable.ic_dialog_email).setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(pending).setAutoCancel(true).setCategory(NotificationCompat.CATEGORY_MESSAGE).setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(generic).build()
        manager.notify(peer.hashCode(),notification)
    }
}
