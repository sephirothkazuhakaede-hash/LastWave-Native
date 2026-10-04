package com.seph.capyflow

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream

// Bound both dimensions and bytes to the common iOS/Android Firestore limit.
fun boundedJpeg(original: Bitmap,limit:Int=131072):ByteArray {
    var width=minOf(original.width,512)
    while(width>=64){
        val height=maxOf(1,(original.height.toDouble()*width/original.width).toInt())
        val bitmap=Bitmap.createScaledBitmap(original,width,height,true)
        for(quality in listOf(88,75,60,45)){
            val output=ByteArrayOutputStream();bitmap.compress(Bitmap.CompressFormat.JPEG,quality,output)
            if(output.size()<=limit)return output.toByteArray()
        }
        width=(width*.75).toInt()
    }
    error("Please choose a smaller image")
}
