package com.seph.capyflow

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.*
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

data class AndroidUpdate(val code:Int,val name:String,val url:String,val sha256:String)
object UpdatePolicy {
    const val RELEASES="https://api.github.com/repos/sephirothkazuhakaede-hash/LastWave-Native/releases?per_page=30"
    const val ASSET_PREFIX="https://github.com/sephirothkazuhakaede-hash/LastWave-Native/releases/download/android-dev"
    fun trustedURL(value:String)=value.startsWith(ASSET_PREFIX) && !value.contains("..") && !value.contains("?") && !value.contains("#")
    fun parse(json:JSONObject,current:Int):AndroidUpdate?{
        val code=json.getInt("versionCode");val url=json.getString("apkURL");val hash=json.getString("sha256").lowercase()
        require(trustedURL(url) && url.endsWith(".apk")){"Update download is not from CapyFlow’s repository"}
        require(hash.matches(Regex("[0-9a-f]{64}"))){"Update checksum is invalid"}
        return if(code>current)AndroidUpdate(code,json.getString("versionName"),url,hash) else null
    }
}
class AppUpdater(app:Application):AndroidViewModel(app){
    var available by mutableStateOf<AndroidUpdate?>(null);private set
    var busy by mutableStateOf(false);private set
    var status by mutableStateOf("");private set
    var progress by mutableStateOf<Float?>(null);private set
    var ready by mutableStateOf<File?>(null);private set
    private val client=OkHttpClient.Builder().connectTimeout(20,TimeUnit.SECONDS).readTimeout(90,TimeUnit.SECONDS).build()
    private fun text(url:String)=client.newCall(Request.Builder().url(url).header("User-Agent","CapyFlow-Android").build()).execute().use{r->check(r.isSuccessful){"Update server returned ${r.code}"};val body=r.body ?: error("Empty update response");check(body.contentLength()<=2_000_000){"Update response is too large"};body.byteStream().use{input->val output=java.io.ByteArrayOutputStream();val bytes=ByteArray(8192);while(true){val count=input.read(bytes);if(count<0)break;check(output.size()+count<=2_000_000){"Update response is too large"};output.write(bytes,0,count)};output.toString("UTF-8")}}
    fun check(){if(busy)return;busy=true;status="Checking GitHub…";available=null
        viewModelScope.launch{try{
            val latest=withContext(Dispatchers.IO){
                val releases=JSONArray(text(UpdatePolicy.RELEASES));var found:AndroidUpdate?=null
                for(i in 0 until releases.length()){
                    val release=releases.getJSONObject(i);if(release.optBoolean("draft") || !release.optString("tag_name").matches(Regex("android-dev[0-9]+")))continue
                    val assets=release.getJSONArray("assets")
                    for(j in 0 until assets.length()){val asset=assets.getJSONObject(j);if(asset.getString("name")!="android-update.json")continue
                        val url=asset.getString("browser_download_url");if(!UpdatePolicy.trustedURL(url))continue
                        val candidate=UpdatePolicy.parse(JSONObject(text(url)),BuildConfig.VERSION_CODE)
                        if(candidate!=null && candidate.code>(found?.code ?: 0))found=candidate
                    }
                };found
            };available=latest;status=if(latest==null)"You’re using the latest published build." else "${latest.name} is available."
        }catch(e:Exception){status="Couldn’t check updates: ${e.message}"}finally{busy=false}}
    }
    fun download(){val update=available ?: return;if(busy)return;busy=true;ready=null;progress=0f;status="Downloading ${update.name}…"
        viewModelScope.launch{try{val file=withContext(Dispatchers.IO){
            val directory=File(getApplication<Application>().cacheDir,"updates").apply{mkdirs()};val part=File(directory,"preview.apk.part");val destination=File(directory,"preview.apk")
            try{
                client.newCall(Request.Builder().url(update.url).build()).execute().use{response->
                    check(response.isSuccessful){"Download returned ${response.code}"};val body=response.body ?: error("Empty download");val length=body.contentLength();check(length in 1..104857600){"Unexpected APK size"}
                    val digest=MessageDigest.getInstance("SHA-256");var count=0L
                    body.byteStream().use{input->part.outputStream().use{output->val bytes=ByteArray(65536);while(true){val size=input.read(bytes);if(size<0)break;count+=size;check(count<=104857600){"APK exceeds size limit"};output.write(bytes,0,size);digest.update(bytes,0,size);val fraction=count.toFloat()/length;if(fraction-(progress ?: 0f)>=.01f)withContext(Dispatchers.Main){progress=fraction}}}}
                    check(count==length){"Incomplete APK download"};check(digest.digest().joinToString(""){"%02x".format(it)}==update.sha256){"APK checksum mismatch"}
                }
                verify(part,update.code);destination.delete();check(part.renameTo(destination)){"Couldn’t save APK"};destination
            }finally{part.delete()}
        };ready=file;available=null;status="Update verified. Tap Install update."}catch(e:Exception){status="Update wasn’t installed: ${e.message}"}finally{busy=false;progress=null}}
    }
    private fun verify(file:File,code:Int){
        val app=getApplication<Application>();val pm=app.packageManager;val flags=if(Build.VERSION.SDK_INT>=28)PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive=pm.getPackageArchiveInfo(file.absolutePath,flags) ?: error("Invalid APK")
        val installed=pm.getPackageInfo(app.packageName,flags)
        check(archive.packageName==app.packageName){"APK belongs to another app"}
        val version=if(Build.VERSION.SDK_INT>=28)archive.longVersionCode else archive.versionCode.toLong();check(version==code.toLong() && version>BuildConfig.VERSION_CODE){"APK version does not match update"}
        @Suppress("DEPRECATION") fun certificates(info:android.content.pm.PackageInfo):Set<String>{val signatures=if(Build.VERSION.SDK_INT>=28)info.signingInfo?.apkContentsSigners else info.signatures;return signatures.orEmpty().map{MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString(""){b->"%02x".format(b)}}.toSet()}
        val current=certificates(installed);check(current.isNotEmpty() && certificates(archive)==current){"APK signing key differs from the installed app"}
    }
    fun install(context:Context){val file=ready ?: return
        try{if(Build.VERSION.SDK_INT>=26 && !context.packageManager.canRequestPackageInstalls()){
            status="Allow CapyFlow to install updates, return here, then tap Install update again."
            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:${context.packageName}")));return
        }
            val uri=FileProvider.getUriForFile(context,"${context.packageName}.updates",file)
            context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        }catch(e:Exception){status="Couldn’t open Android installer: ${e.message}"}
    }
}
