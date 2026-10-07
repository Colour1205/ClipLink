package io.uaena.cliplink

import io.uaena.cliplink.ui.localNetworkAccessOff
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** When the Synced screen's status pill says "Local network access is off". */
class LocalNetworkAccessTest {

    @Test
    fun deniedOnAndroid17IsOff() {
        assertTrue(localNetworkAccessOff(sdkInt = 37, permissionGranted = false))
    }

    @Test
    fun grantedOnAndroid17IsNotOff() {
        assertFalse(localNetworkAccessOff(sdkInt = 37, permissionGranted = true))
    }

    @Test
    fun beforeAndroid17ThereIsNothingToBeOff() {
        // The permission doesn't exist there, so "not granted" means nothing.
        assertFalse(localNetworkAccessOff(sdkInt = 36, permissionGranted = false))
        assertFalse(localNetworkAccessOff(sdkInt = 31, permissionGranted = false))
    }
}
