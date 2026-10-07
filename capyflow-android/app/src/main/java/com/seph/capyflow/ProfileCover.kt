package com.seph.capyflow

import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.Alignment
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LocalLifecycleOwner
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import coil.request.ImageRequest

object ProfileCoverChoice {
    const val NONE = "none"
    const val PARADE = "capy-parade-v1"
    fun normalized(value: String?) = value?.takeIf{it.matches(Regex("[a-z0-9][a-z0-9_-]{0,63}"))} ?: NONE
}

@Composable fun ProfileCover(coverID: String) {
    val library=rememberProfileBannerLibrary()
    if(!library.shows(coverID)) return
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val banner=library.banners.firstOrNull{it.id==coverID}
    var asset by remember(coverID,banner?.revision){mutableStateOf<java.io.File?>(null)}
    LaunchedEffect(coverID,banner?.revision,library.root) {
        if(banner!=null) try{asset=ProfileBannerRepository.asset(context,library,banner)}
        catch(e:kotlinx.coroutines.CancellationException){throw e}
        catch(_:Exception){ }
    }
    val loader = remember(context) {
        ImageLoader.Builder(context).components {
            if(Build.VERSION.SDK_INT >= 28) add(ImageDecoderDecoder.Factory())
            else add(GifDecoder.Factory())
        }.build()
    }
    DisposableEffect(loader) { onDispose { loader.shutdown() } }
    val request = remember(context, lifecycle,asset,coverID) {
        ImageRequest.Builder(context).data(asset ?: R.drawable.capy_profile_parade)
            .lifecycle(lifecycle).size(720, 300).allowHardware(false).build()
    }
    AsyncImage(model=request, imageLoader=loader, contentDescription=null,
        contentScale=ContentScale.Crop,
        modifier=Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(22.dp)))
}

@Composable fun ProfileIdentityHeader(profile: Profile?) {
    val library=rememberProfileBannerLibrary()
    if(profile!=null && library.shows(profile.coverID)) {
        Box(Modifier.fillMaxWidth().height(203.dp)) {
            ProfileCover(profile.coverID)
            Box(Modifier.align(Alignment.BottomCenter).background(Night, CircleShape).padding(5.dp)) {
                ProfileAvatar(profile, 96)
            }
        }
    } else {
        ProfileAvatar(profile, 96)
    }
}
