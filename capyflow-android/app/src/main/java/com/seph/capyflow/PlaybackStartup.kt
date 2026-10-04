package com.seph.capyflow

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

/** Start a second resolver only when the primary is slow; consume the first success. */
internal suspend fun <T> firstWorkingSource(fallbackDelayMs:Long,primary:suspend ()->T,fallback:suspend ()->T):T=supervisorScope {
    val replies=Channel<Pair<Boolean,Result<T>>>(2)
    val primaryFailed=CompletableDeferred<Unit>()
    suspend fun run(first:Boolean,source:suspend ()->T){
        try{replies.send(first to Result.success(source()))}
        catch(e:Exception){currentCoroutineContext().ensureActive();if(first)primaryFailed.complete(Unit);replies.send(first to Result.failure(e))}
    }
    val a=launch{run(true,primary)}
    val b=launch{withTimeoutOrNull(fallbackDelayMs){primaryFailed.await()};run(false,fallback)}
    try{
        var failure:Throwable?=null
        repeat(2){val (_,result)=replies.receive();if(result.isSuccess)return@supervisorScope result.getOrThrow();failure=result.exceptionOrNull()}
        throw failure ?: IllegalStateException("No playable source")
    }finally{a.cancel();b.cancel();replies.close()}
}
