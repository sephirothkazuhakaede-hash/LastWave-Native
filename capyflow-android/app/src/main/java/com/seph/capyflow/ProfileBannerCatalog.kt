package com.seph.capyflow

import android.content.Context
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

data class ProfileBanner(val id:String,val name:String,val revision:String,val path:String)
data class ProfileBannerLibrary(val banners:List<ProfileBanner> = emptyList(),val hasCatalog:Boolean=false,val root:String="") {
    fun shows(id:String)=banners.any{it.id==id} || (!hasCatalog && id==ProfileCoverChoice.PARADE)
}
internal object ProfileBannerRepository {
    private val http=OkHttpClient.Builder().connectTimeout(5,TimeUnit.SECONDS).readTimeout(15,TimeUnit.SECONDS).followRedirects(false).build()
    private fun directory(context:Context)=File(context.cacheDir,"profile-banners").apply{mkdirs()}
    private fun parse(raw:String,root:String):ProfileBannerLibrary {
        val json=JSONObject(raw);require(json.getInt("schemaVersion")==1)
        val entries=json.getJSONArray("banners");require(entries.length()<=100)
        val banners=(0 until entries.length()).map{index ->
            val item=entries.getJSONObject(index);val id=item.getString("id");val revision=item.getString("revision");val path=item.getString("path")
            require(ProfileCoverChoice.normalized(id)==id && id!=ProfileCoverChoice.NONE && revision.matches(Regex("[a-f0-9]{64}")) && path=="/v1/profile-banners/$id/$revision.gif")
            ProfileBanner(id,item.getString("name"),revision,path)
        }.sortedBy{it.name.lowercase()}
        return ProfileBannerLibrary(banners,true,root)
    }
    fun cached(context:Context)=runCatching {
        val saved=JSONObject(File(directory(context),"catalog.json").readText())
        parse(saved.getString("catalog"),saved.getString("root"))
    }.getOrDefault(ProfileBannerLibrary())
    suspend fun refresh(context:Context):ProfileBannerLibrary=withContext(Dispatchers.IO) {
        val prefs=context.getSharedPreferences("capyflow",0)
        var root=prefs.getString("server","").orEmpty().trimEnd('/')
        if(root.isBlank()) {
            val raw=read("https://raw.githubusercontent.com/sephirothkazuhakaede-hash/LastWave-Native/runtime/backend-discovery/backend.json",262144)
            root=JSONObject(String(raw)).getString("url").trimEnd('/')
        }
        val url=root.toHttpUrl();require(url.isHttps || url.host in setOf("localhost","127.0.0.1") || url.host.startsWith("192.168.") || url.host.startsWith("10."))
        root=root.removeSuffix("/v1")
        val raw=String(read("$root/v1/profile-banners",262144));val parsed=parse(raw,root)
        val file=File(directory(context),"catalog.json");val temp=File(directory(context),"catalog-${java.util.UUID.randomUUID()}.tmp")
        temp.writeText(JSONObject().put("root",root).put("catalog",raw).toString());check(temp.renameTo(file))
        parsed
    }
    suspend fun asset(context:Context,library:ProfileBannerLibrary,banner:ProfileBanner):File=withContext(Dispatchers.IO) {
        val file=File(directory(context),"${banner.id}-${banner.revision}.gif")
        if(file.exists())return@withContext file
        val data=read(library.root+banner.path,5*1024*1024)
        require(data.size>=6 && String(data,0,6) in listOf("GIF87a","GIF89a"))
        val temp=File(directory(context),"${banner.id}-${java.util.UUID.randomUUID()}.tmp");temp.writeBytes(data);check(temp.renameTo(file))
        directory(context).listFiles()?.filter{it.extension=="gif"}?.sortedByDescending{it.lastModified()}?.drop(20)?.forEach{it.delete()}
        file
    }
    private fun read(url:String,limit:Int):ByteArray=http.newCall(Request.Builder().url(url).build()).execute().use { response ->
        check(response.isSuccessful);val body=response.body ?: error("Missing banner response")
        require(body.contentLength()<=limit)
        body.byteStream().use { stream -> val output=java.io.ByteArrayOutputStream();val buffer=ByteArray(8192)
            while(true){val count=stream.read(buffer);if(count<0)break;require(output.size()+count<=limit);output.write(buffer,0,count)};output.toByteArray() }
    }
}

@Composable fun rememberProfileBannerLibrary():ProfileBannerLibrary {
    val context=LocalContext.current.applicationContext
    var library by remember(context){mutableStateOf(ProfileBannerRepository.cached(context))}
    LaunchedEffect(context) {
        while(isActive) {
            try { library=ProfileBannerRepository.refresh(context) }
            catch(e:CancellationException){throw e}
            catch(_:Exception){ }
            delay(60_000)
        }
    }
    return library
}
