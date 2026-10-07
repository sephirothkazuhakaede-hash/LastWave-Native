package com.seph.capyflow

import android.os.Build
import androidx.compose.foundation.layout.*
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
    fun normalized(value: String?) = if(value == PARADE) PARADE else NONE
}

@Composable fun ProfileCover(coverID: String) {
    if(coverID != ProfileCoverChoice.PARADE) return
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current
    val loader = remember(context) {
        ImageLoader.Builder(context).components {
            if(Build.VERSION.SDK_INT >= 28) add(ImageDecoderDecoder.Factory())
            else add(GifDecoder.Factory())
        }.build()
    }
    DisposableEffect(loader) { onDispose { loader.shutdown() } }
    val request = remember(context, lifecycle) {
        ImageRequest.Builder(context).data(R.drawable.capy_profile_parade)
            .lifecycle(lifecycle).size(720, 300).allowHardware(false).build()
    }
    AsyncImage(model=request, imageLoader=loader, contentDescription=null,
        contentScale=ContentScale.Crop,
        modifier=Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(22.dp)))
}
