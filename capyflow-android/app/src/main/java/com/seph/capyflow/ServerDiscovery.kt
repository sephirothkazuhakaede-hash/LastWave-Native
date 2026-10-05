package com.seph.capyflow

import kotlinx.coroutines.ensureActive

/** An in-flight discovery response must never override a newer Settings choice. */
internal suspend fun refreshDiscoveredServer(
    epoch: Int,
    currentEpoch: () -> Int,
    automatic: () -> Boolean,
    discover: suspend () -> String,
    accept: (String) -> Unit,
) {
    if (!automatic()) return
    val found = discover()
    kotlinx.coroutines.currentCoroutineContext().ensureActive()
    if (automatic() && epoch == currentEpoch()) accept(found)
}

internal class HttpResponseException(val status:Int):java.io.IOException("Service request failed ($status)")

/** Retry a cold connection once, while keeping cancellation and invalid addresses final. */
internal suspend fun discoverWithRetry(
    pause:suspend ()->Unit={kotlinx.coroutines.delay(250)},
    operation:suspend ()->String
):String {
    repeat(2){attempt ->
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        try{return operation()}
        catch(e:kotlinx.coroutines.CancellationException){throw e}
        catch(e:java.io.IOException){
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if(attempt==1 || (e is HttpResponseException && e.status !in setOf(408,429,500,502,503,504)))throw e
            pause()
        }
    }
    error("Connection unavailable")
}
