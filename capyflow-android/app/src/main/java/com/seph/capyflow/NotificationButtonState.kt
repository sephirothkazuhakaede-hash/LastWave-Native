package com.seph.capyflow

internal enum class NotificationButtonState(val label:String){
    NEEDS_SETUP("Enable notifications"),
    REGISTERING("Enabling notifications…"),
    ENABLED("Notifications enabled")
}
internal fun notificationButtonState(allowed:Boolean,registered:Boolean,registering:Boolean)=when{
    !allowed->NotificationButtonState.NEEDS_SETUP
    registering->NotificationButtonState.REGISTERING
    registered->NotificationButtonState.ENABLED
    else->NotificationButtonState.NEEDS_SETUP
}
