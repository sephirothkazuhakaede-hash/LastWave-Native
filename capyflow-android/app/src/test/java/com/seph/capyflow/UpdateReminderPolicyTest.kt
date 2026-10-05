package com.seph.capyflow
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
class UpdateReminderPolicyTest {
    @Test fun laterDefersSameUpdateButNewerVersionStillAppears(){
        assertFalse(UpdateReminderPolicy.shouldPrompt(10,10,2000,1000))
        assertTrue(UpdateReminderPolicy.shouldPrompt(10,10,2000,2000))
        assertTrue(UpdateReminderPolicy.shouldPrompt(11,10,2000,1000))
    }
    @Test fun checksAreThrottledAndRecoverAfterClockChanges(){
        assertTrue(UpdateReminderPolicy.shouldCheck(0,1000))
        assertFalse(UpdateReminderPolicy.shouldCheck(1000,2000))
        assertTrue(UpdateReminderPolicy.shouldCheck(1000,1000+4*3600000L))
        assertTrue(UpdateReminderPolicy.shouldCheck(2000,1000))
    }
    @Test fun releaseNotesAreAvailableToTheAnnouncement(){
        val json=JSONObject().put("versionCode",10).put("versionName","dev10")
            .put("apkURL",UpdatePolicy.ASSET_PREFIX+"10/CapyFlow.apk")
            .put("sha256","a".repeat(64)).put("releaseNotes","Fix chat receipts")
        assertEquals("Fix chat receipts",UpdatePolicy.parse(json,9)?.notes)
    }
}
