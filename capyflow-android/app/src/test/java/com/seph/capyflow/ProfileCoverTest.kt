package com.seph.capyflow

import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileCoverTest {
    @Test fun coverIdentityIsSharedAndOldProfilesKeepDefault() {
        assertEquals("none", ProfileCoverChoice.normalized(null))
        assertEquals("none", ProfileCoverChoice.normalized("../unknown"))
        assertEquals("capy-parade-v1", ProfileCoverChoice.normalized("capy-parade-v1"))
    }
}
