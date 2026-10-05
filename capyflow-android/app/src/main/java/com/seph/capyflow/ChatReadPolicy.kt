package com.seph.capyflow

object ChatReadPolicy {
    fun canObserveThread(exists:Boolean,pending:Boolean)=exists && !pending
    fun shouldMarkRead(displayed:String,latest:String?,sender:String?,user:String,read:String?)=
        latest==displayed && sender!=null && sender!=user && read!=displayed
}
