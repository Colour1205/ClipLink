package io.uaena.cliplink.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

/**
 * Whether [permission] is granted - and kept up to date: it is checked again
 * every time the app comes back to the foreground, because the way to change
 * it is the system settings, which this app was just sent to.
 */
@Composable
fun rememberPermissionGranted(permission: String): Boolean {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember(permission) { mutableStateOf(isPermissionGranted(context, permission)) }
    DisposableEffect(owner, permission) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) granted = isPermissionGranted(context, permission)
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    return granted
}

private fun isPermissionGranted(context: Context, permission: String): Boolean =
    ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

/**
 * True when local network access is off, which at targetSdk 37 silently breaks
 * everything on the LAN (UDP sends fail with EPERM, TCP dials hang) and looks
 * exactly like "no devices exist". Before Android 17 there is no such
 * permission, so nothing can be off.
 */
fun localNetworkAccessOff(sdkInt: Int, permissionGranted: Boolean): Boolean =
    sdkInt >= LOCAL_NETWORK_PERMISSION_SDK && !permissionGranted

private const val LOCAL_NETWORK_PERMISSION_SDK = 37

/** [localNetworkAccessOff] for this device, live. Read straight from the system, not from the engine. */
@Composable
fun rememberLocalNetworkAccessOff(): Boolean {
    val granted = rememberPermissionGranted(Manifest.permission.ACCESS_LOCAL_NETWORK)
    return localNetworkAccessOff(Build.VERSION.SDK_INT, granted)
}

/** This app's page in the system settings, where its permissions can be changed. Never throws. */
fun openAppSettings(context: Context) {
    runCatching {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
