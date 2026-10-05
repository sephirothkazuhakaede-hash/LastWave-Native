package com.seph.capyflow

import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationButtonStateTest {
    @Test fun successRequiresPermissionAndRegistration(){
        assertEquals(NotificationButtonState.ENABLED,notificationButtonState(true,true,false))
        assertEquals(NotificationButtonState.NEEDS_SETUP,notificationButtonState(true,false,false))
        assertEquals(NotificationButtonState.NEEDS_SETUP,notificationButtonState(false,true,false))
    }
    @Test fun pendingAndFailedRegistrationRemainDistinct(){
        assertEquals(NotificationButtonState.REGISTERING,notificationButtonState(true,false,true))
        assertEquals(NotificationButtonState.NEEDS_SETUP,notificationButtonState(true,false,false))
        assertEquals(NotificationButtonState.NEEDS_SETUP,notificationButtonState(false,false,true))
    }
}
