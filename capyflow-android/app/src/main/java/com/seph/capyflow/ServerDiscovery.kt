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
