package com.seph.capyflow

class PeopleSearchGate {
    private var generation=0L
    fun begin(query:String):Long { generation++;return generation }
    fun clear(){generation++}
    fun accepts(request:Long)=request==generation
    companion object { fun normalize(raw:String)=raw.trim().removePrefix("@").lowercase(java.util.Locale.ROOT) }
}
data class AppNotice(val title:String,val body:String,val peerID:String?=null,val id:Long=System.nanoTime(),val global:Boolean=false)
fun activityStatus(playing:Boolean,updated:Long,expires:Long,now:Long):String {
    if(playing && expires>now && updated>0 && now-updated<300000)return "Listening now"
    if(updated<=0)return "Listened recently"
    val minutes=((now-updated).coerceAtLeast(0)/60000)
    return when { minutes<1->"Listened just now";minutes<60->"Listened ${minutes}m ago";minutes<1440->"Listened ${minutes/60}h ago";else->"Listened ${minutes/1440}d ago" }
}
