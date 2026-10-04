package com.seph.capyflow

import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    override fun onCreate() {
        super.onCreate()
        val http = OkHttpClient.Builder().readTimeout(90, TimeUnit.SECONDS).addInterceptor { chain ->
            val request = chain.request()
            // Attach credentials only for the exact server this app resolved.
            val trusted = PlaybackAuthorization.host
            val token = PlaybackAuthorization.token
            val baseRequest=if(request.url.host.endsWith(".googlevideo.com"))request.newBuilder().header("User-Agent",DirectMusic.USER_AGENT).build() else request
            val signed = if (request.url.isHttps && request.url.host == trusted && token != null)
                baseRequest.newBuilder().header("Authorization", "Bearer $token").build() else baseRequest
            chain.proceed(signed)
        }.build()
        val renderers=androidx.media3.exoplayer.DefaultRenderersFactory(this).setEnableDecoderFallback(true).setEnableAudioFloatOutput(false).setEnableAudioTrackPlaybackParams(false)
        val player = ExoPlayer.Builder(this,renderers).setMediaSourceFactory(DefaultMediaSourceFactory(androidx.media3.datasource.DefaultDataSource.Factory(this, OkHttpDataSource.Factory(http)))).build()
        player.setAudioAttributes(androidx.media3.common.AudioAttributes.Builder()
            .setUsage(androidx.media3.common.C.USAGE_MEDIA).setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
        player.setHandleAudioBecomingNoisy(true)
        session = MediaSession.Builder(this, player).build()
    }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session
    override fun onDestroy() { session?.run { player.release(); release() }; session = null; super.onDestroy() }
}
object PlaybackAuthorization { @Volatile var host: String? = null; @Volatile var token: String? = null }
