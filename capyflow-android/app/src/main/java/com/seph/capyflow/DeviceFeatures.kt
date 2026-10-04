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
    Text("Download a verified update, then confirm installation with Android. Your account and local data stay in place.",color=androidx.compose.ui.graphics.Color.White.copy(alpha=.6f))
    Button(onClick={updater.check()},enabled=!updater.busy){Icon(Icons.Default.SystemUpdate,null);Spacer(Modifier.width(8.dp));Text(if(updater.busy)"Working…" else "Check for updates")}
    if(updater.progress!=null)LinearProgressIndicator(progress={updater.progress ?: 0f},modifier=Modifier.fillMaxWidth())
    updater.available?.let{update->Text(update.name,color=Violet);Button(onClick={updater.download()},enabled=!updater.busy){Icon(Icons.Default.Download,null);Text("Download update",modifier=Modifier.padding(start=8.dp))}}
    if(updater.ready!=null)Button(onClick={updater.install(context)},enabled=!updater.busy){Text("Install update")}
    if(updater.status.isNotBlank())Text(updater.status,fontSize=13.sp,color=Violet)
}
