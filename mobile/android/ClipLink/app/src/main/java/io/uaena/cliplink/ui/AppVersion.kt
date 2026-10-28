package io.uaena.cliplink.ui

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * What the Me screen shows after the word "Version": the version name, then
 * the build number in brackets when there is one - "2.0 (3)", the same shape
 * as iOS. Null when there is no version name to show.
 */
fun versionDetail(versionName: String?, build: Long?): String? {
    val name = versionName?.trim().orEmpty()
    if (name.isEmpty()) return null
    return if (build == null) name else "$name ($build)"
}

/**
 * [versionDetail] of this app, read from the installed package rather than
 * written out here, so bumping versionName and versionCode in the build file
 * is all a release takes. Null when the package can't be read; never throws.
 */
fun appVersionDetail(context: Context): String? = runCatching {
    val manager = context.packageManager
    val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        manager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
    } else {
        @Suppress("DEPRECATION")
        manager.getPackageInfo(context.packageName, 0)
    }
    versionDetail(info.versionName, info.longVersionCode)
}.getOrNull()
