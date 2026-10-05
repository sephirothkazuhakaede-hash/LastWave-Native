package com.seph.capyflow

import org.json.JSONObject
import java.util.Base64

/** Explicit refresh reads the branch API rather than a potentially stale raw-file CDN. */
internal fun discoveryDocument(response:String,api:Boolean):JSONObject {
    val document=JSONObject(response)
    if(!api)return document
    require(document.getString("encoding")=="base64"){"Invalid connection document"}
    val encoded=document.getString("content").filterNot(Char::isWhitespace)
    return JSONObject(String(Base64.getDecoder().decode(encoded),Charsets.UTF_8))
}
