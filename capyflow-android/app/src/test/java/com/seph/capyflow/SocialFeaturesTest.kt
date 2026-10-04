package com.seph.capyflow
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
class SocialFeaturesTest {
    @Test fun clearedOrSupersededSearchCannotReappear(){val gate=PeopleSearchGate();val old=gate.begin("seph");val next=gate.begin("other");assertFalse(gate.accepts(old));assertTrue(gate.accepts(next));gate.clear();assertFalse(gate.accepts(next));assertEquals("seph",PeopleSearchGate.normalize(" @Seph "))}
    @Test fun stalePresenceIsNeverLabeledLive(){val now=10000000L;assertEquals("Listening now",activityStatus(true,now-10000,now+60000,now));assertEquals("Listened 6m ago",activityStatus(true,now-360000,now-1000,now));assertEquals("Listened 1h ago",activityStatus(false,now-3600000,now-1000,now));assertEquals("Listened recently",activityStatus(false,0,0,now))}
    @Test fun updaterRejectsForeignURLsAndMalformedChecksums(){fun json(url:String,hash:String)=JSONObject().put("versionCode",10).put("versionName","dev10").put("apkURL",url).put("sha256",hash)
        val good=UpdatePolicy.ASSET_PREFIX+"10/CapyFlow.apk";assertEquals(10,UpdatePolicy.parse(json(good,"a".repeat(64)),9)?.code);assertNull(UpdatePolicy.parse(json(good,"a".repeat(64)),10))
        assertTrue(runCatching{UpdatePolicy.parse(json("https://example.com/fake.apk","a".repeat(64)),9)}.isFailure)
        assertTrue(runCatching{UpdatePolicy.parse(json(good,"fake"),9)}.isFailure)
        assertFalse(UpdatePolicy.trustedURL(UpdatePolicy.ASSET_PREFIX+"9/../evil.apk"))
    }
}
