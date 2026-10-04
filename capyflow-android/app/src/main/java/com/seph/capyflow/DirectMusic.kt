package com.seph.capyflow

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.MediaFormat
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.localization.Localization
import org.schabi.newpipe.extractor.localization.ContentCountry
import org.schabi.newpipe.extractor.stream.AudioTrackType
import org.schabi.newpipe.extractor.stream.DeliveryMethod
import java.util.concurrent.TimeUnit

internal data class DirectAudio(val url: String, val container: String, val codec: String?, val bitrateKbps: Double?, val sampleRateHz: Int?, val original: Boolean = true)
internal data class DirectResolution(val audio: DirectAudio, val duration: Double?, val qualityCount: Int) {
    fun info() = JSONObject().put("codec",audio.codec).put("container",audio.container)
        .put("bitrateKbps",audio.bitrateKbps).put("sampleRateHz",audio.sampleRateHz).put("availableQualityCount",qualityCount)
}

internal fun selectDirectAudio(candidates: List<DirectAudio>, quality: String): DirectAudio {
    val original=candidates.filter{it.original}.ifEmpty{candidates}
    val compatible=original.filter{it.container=="m4a"}.ifEmpty{original}
    check(compatible.isNotEmpty()){ "This upload has no compatible audio stream." }
    val known=compatible.filter{it.bitrateKbps!=null && it.bitrateKbps>0}
    if(known.isEmpty())return compatible.first()
    return if(quality=="dataSaver")known.minBy{it.bitrateKbps!!} else known.maxBy{it.bitrateKbps!!}
}

internal object DirectMusic {
    private val client=OkHttpClient.Builder().connectTimeout(8,TimeUnit.SECONDS).readTimeout(15,TimeUnit.SECONDS).callTimeout(20,TimeUnit.SECONDS).build()
    private val downloader=object: Downloader() {
        override fun execute(request: Request): Response {
            if(Thread.currentThread().isInterrupted)throw java.io.InterruptedIOException()
            val builder=okhttp3.Request.Builder().url(request.url()).header("User-Agent",USER_AGENT)
            request.headers().forEach{(name,values) -> values.forEach{builder.addHeader(name,it)}}
            val data=request.dataToSend();val method=request.httpMethod()
            builder.method(method,if(data!=null)data.toRequestBody(null) else if(method=="POST")ByteArray(0).toRequestBody(null) else null)
            val call=client.newCall(builder.build())
            call.execute().use{r -> return Response(r.code,r.message,r.headers.toMultimap(),r.body?.string(),r.request.url.toString())}
        }
    }
    init { NewPipe.init(downloader,Localization("en","PH"),ContentCountry("PH")) }
    suspend fun resolve(id: String,quality: String): DirectResolution = runInterruptible(Dispatchers.IO) {
        val extractor=ServiceList.YouTube.getStreamExtractor("https://www.youtube.com/watch?v=$id")
        extractor.fetchPage()
        val candidates=extractor.audioStreams.filter { it.isUrl && it.deliveryMethod==DeliveryMethod.PROGRESSIVE_HTTP && it.content.startsWith("https://") }.map { stream ->
            val bitrate=stream.averageBitrate.takeIf{it>0}?.toDouble() ?: stream.bitrate.takeIf{it>0}?.div(1000.0)
            DirectAudio(stream.content,if(stream.format==MediaFormat.M4A)"m4a" else "webm",stream.codec,bitrate,stream.itagItem?.sampleRate?.takeIf{it>0},stream.audioTrackType==null || stream.audioTrackType==AudioTrackType.ORIGINAL)
        }
        val selected=selectDirectAudio(candidates,quality)
        val comparable=candidates.filter{it.original && it.container==selected.container}.ifEmpty{candidates.filter{it.container==selected.container}}
        DirectResolution(selected,extractor.length.takeIf{it>0}?.toDouble(),comparable.mapNotNull{it.bitrateKbps}.distinct().size)
    }
    const val USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}
