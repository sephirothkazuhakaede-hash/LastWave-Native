package com.seph.capyflow

import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** Only intentionally written validation messages may reach a user-facing screen. */
internal object UserMessages {
    private val validation = setOf(
        "Couldn’t reserve a username. Please sign in again.",
        "Your profile is still loading.",
        "That username is already taken.",
        "You can change your username once every 14 days.",
        "Only the owner can invite collaborators",
        "You are no longer a collaborator",
        "Playlist unavailable",
        "Choose an image",
        "Couldn’t open image",
        "Couldn’t open photo"
    )
    fun failure(error:Throwable?,fallback:String="Couldn’t finish that action. Please try again."):String {
        val causes=generateSequence(error){it.cause}.take(6).toList()
        causes.firstNotNullOfOrNull{it.message?.takeIf(validation::contains)}?.let{return it}
        if(causes.any{it is SocketTimeoutException})return "The connection timed out. Please try again."
        if(causes.any{it is UnknownHostException || it is ConnectException})return "Check your connection and try again."
        if(causes.any{it.message?.contains("ENOSPC")==true})return "Not enough storage. Free up some space and try again."
        return fallback
    }
}
