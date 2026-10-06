package com.seph.capyflow

import android.content.Context
import android.content.Intent
import android.media.MediaRouter
import android.media.MediaRouter2
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable fun AudioOutputButton(){
    val context=LocalContext.current
    val router=remember{context.getSystemService(Context.MEDIA_ROUTER_SERVICE) as MediaRouter}
    var name by remember{mutableStateOf(router.getSelectedRoute(MediaRouter.ROUTE_TYPE_LIVE_AUDIO).name.toString())}
    DisposableEffect(router){
        val callback=object:MediaRouter.SimpleCallback(){
            override fun onRouteSelected(r:MediaRouter,type:Int,route:MediaRouter.RouteInfo){name=route.name.toString()}
            override fun onRouteChanged(r:MediaRouter,route:MediaRouter.RouteInfo){name=r.getSelectedRoute(MediaRouter.ROUTE_TYPE_LIVE_AUDIO).name.toString()}
        }
        router.addCallback(MediaRouter.ROUTE_TYPE_LIVE_AUDIO,callback)
        onDispose{router.removeCallback(callback)}
    }
    TextButton(onClick={
        val shown=if(Build.VERSION.SDK_INT>=34)runCatching{MediaRouter2.getInstance(context).showSystemOutputSwitcher()}.getOrDefault(false) else false
        if(!shown)runCatching{context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))}
    },contentPadding=PaddingValues(horizontal=8.dp,vertical=0.dp)){
        Icon(Icons.Default.SpeakerGroup,"Choose audio output",modifier=Modifier.size(16.dp),tint=Violet)
        Spacer(Modifier.width(5.dp));Text(name,maxLines=1,fontSize=11.sp,color=Violet)
    }
}
@Composable fun UpdateSettings(){
    val updater:AppUpdater=viewModel();val context=LocalContext.current
    Text("CapyFlow ${BuildConfig.VERSION_NAME}")
    Text("Keep CapyFlow up to date. Your account, playlists and downloads stay saved.",color=androidx.compose.ui.graphics.Color.White.copy(alpha=.6f))
    Button(onClick={updater.check()},enabled=!updater.busy){Icon(Icons.Default.SystemUpdate,null);Spacer(Modifier.width(8.dp));Text(if(updater.busy)"Working…" else "Check for updates")}
    if(updater.progress!=null)LinearProgressIndicator(progress={updater.progress ?: 0f},modifier=Modifier.fillMaxWidth())
    updater.available?.let{update->Text(update.name,color=Violet);if(update.notes.isNotBlank()){Text("What’s new",fontSize=16.sp);Text(update.notes,fontSize=13.sp)};Button(onClick={updater.download(context)},enabled=!updater.busy){Icon(Icons.Default.Download,null);Text("Update now",modifier=Modifier.padding(start=8.dp))}}
    if(updater.ready!=null)Button(onClick={updater.install(context)},enabled=!updater.busy){Text("Install update")}
    if(updater.status.isNotBlank())Text(updater.status,fontSize=13.sp,color=Violet)
}

@Composable fun NotificationSettings(){
    val context=LocalContext.current
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    var allowed by remember{mutableStateOf(PushRegistry.allowed(context))}
    fun bind(){
        if(BuildConfig.FIREBASE_CONFIGURED)PushRegistry.bind(context,com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid)
    }
    DisposableEffect(lifecycle,context){
        val observer=androidx.lifecycle.LifecycleEventObserver{_,event->
            if(event==androidx.lifecycle.Lifecycle.Event.ON_RESUME){
                allowed=PushRegistry.allowed(context)
                if(allowed && !PushRegistry.registered && !PushRegistry.registering)bind()
            }
        }
        lifecycle.addObserver(observer)
        onDispose{lifecycle.removeObserver(observer)}
    }
    val permission=androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()){granted->
        allowed=PushRegistry.allowed(context)
        if(granted)bind()
    }
    val state=notificationButtonState(allowed,PushRegistry.registered,PushRegistry.registering)
    Text("In-app notifications")
    listOf("messageBanners" to "Message banners", "globalBanners" to "Global Chat banners", "globalPush" to "Global Chat push notifications").forEach { (key,label) ->
        var enabled by remember { mutableStateOf(ChatPreferences.enabled(context,key,key!="globalPush")) }
        Row(Modifier.fillMaxWidth(),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
            Text(label,modifier=Modifier.weight(1f))
            Switch(checked=enabled,onCheckedChange={value -> enabled=value;ChatPreferences.set(context,key,value);if(key=="globalPush")bind()})
        }
    }
    Text("Banners appear while you use CapyFlow. Global Chat push alerts arrive when the app is in the background and require notification permission.",fontSize=13.sp)
    Text("Message notifications")
    Text(PushRegistry.status,color=Violet,fontSize=13.sp)
    Text("Get alerts for new messages while CapyFlow is in the background.",fontSize=13.sp,color=androidx.compose.ui.graphics.Color.White.copy(alpha=.6f))
    Button(onClick={
        if(Build.VERSION.SDK_INT>=33 && androidx.core.content.ContextCompat.checkSelfPermission(context,android.Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED)
            permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        else if(!PushRegistry.allowed(context))context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName))
        else bind()
    },enabled=state==NotificationButtonState.NEEDS_SETUP){
        if(state==NotificationButtonState.ENABLED)Icon(Icons.Default.CheckCircle,null)
        if(state==NotificationButtonState.REGISTERING)CircularProgressIndicator(Modifier.size(16.dp),strokeWidth=2.dp)
        if(state!=NotificationButtonState.NEEDS_SETUP)Spacer(Modifier.width(8.dp))
        Text(state.label)
    }
    TextButton(onClick={context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE,context.packageName))}){Text("Android notification settings")}
}
