package com.seph.capyflow

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

internal class DownloadHttpException(val status: Int): java.io.IOException("Download failed ($status)")
internal suspend fun retryAudioDownload(wait: suspend (Long)->Unit={delay(it)}, attempt: suspend (Int)->Unit) {
    for(index in 0..2) {
        try {attempt(index);return}
        catch(e: CancellationException){throw e}
        catch(e: Exception){if(index==2 || e is DownloadHttpException && e.status in setOf(400,401,404))throw e;wait(1000L shl index)}
    }
}
