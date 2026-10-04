package com.seph.capyflow

object UsernamePolicy {
    private val reserved=setOf("admin","administrator","api","apple","capyflow","everyone","firebase","google","help","here","moderator","mods","null","official","owner","root","security","staff","support","system","undefined")
    fun valid(value:String)=value.length in 3..20 && Regex("^[a-z0-9_][a-z0-9_.]*[a-z0-9_]$").matches(value) && ".." !in value && value !in reserved
}
