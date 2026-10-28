package io.uaena.cliplink

import io.uaena.cliplink.ui.versionDetail
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The version line on the Me screen: the version name, then the build number in brackets. */
class AppVersionTest {

    @Test
    fun theBuildNumberFollowsTheVersionInBrackets() {
        assertEquals("2.0 (3)", versionDetail("2.0", 3))
    }

    @Test
    fun withoutABuildNumberItIsJustTheVersion() {
        assertEquals("2.0", versionDetail("2.0", null))
    }

    @Test
    fun noVersionNameMeansNothingToShow() {
        assertNull(versionDetail(null, 3))
        assertNull(versionDetail("", 3))
        assertNull(versionDetail("  ", 3))
    }

    @Test
    fun spacesAroundTheVersionNameAreDropped() {
        assertEquals("2.0.1 (12)", versionDetail(" 2.0.1 ", 12))
    }
}
