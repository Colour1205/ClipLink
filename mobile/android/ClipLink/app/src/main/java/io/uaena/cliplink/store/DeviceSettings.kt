package io.uaena.cliplink.store

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.util.Locale

/**
 * Small local preferences that aren't identity or trust.
 *
 * The Tailscale IP is typed in by hand for the same reason as on HarmonyOS:
 * the Windows daemon shells out to `tailscale ip -4` to learn its own tailnet
 * address, and a sandboxed mobile app has no equivalent - there is no API to
 * ask another installed app for its state, and Tailscale exposes none. Once
 * entered it's used exactly the way Windows uses its auto-detected one: in
 * the LAN beacon, so a trusted peer can cache it for later off-LAN
 * reconnects, and in the pairing payload.
 */
class DeviceSettings(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext
        .getSharedPreferences("cliplink_device_settings", Context.MODE_PRIVATE)

    /**
     * The name typed on the Me screen. Empty means "use [systemDeviceName]" -
     * kept that way rather than resolved and stored, so renaming the phone
     * itself later still shows through to peers.
     */
    var deviceNameOverride: String
        get() = prefs.getString(DEVICE_NAME_KEY, "") ?: ""
        set(value) {
            prefs.edit().putString(DEVICE_NAME_KEY, value.trim()).commit()
        }

    /**
     * What the phone calls itself, with no permission needed: the name set
     * under About phone where the platform exposes it, else manufacturer and
     * model. The System "device_name" key is an OEM one, not SDK, and from S
     * on the settings provider can refuse reads of non-SDK keys with a
     * SecurityException - hence runCatching around both reads, not just the
     * unusual one.
     */
    fun systemDeviceName(): String {
        val resolver = appContext.contentResolver
        runCatching { Settings.Global.getString(resolver, Settings.Global.DEVICE_NAME) }
            .getOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        runCatching { Settings.System.getString(resolver, "device_name") }
            .getOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }

        val manufacturer = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        return when {
            manufacturer.isEmpty() -> model
            // "Pixel 8" needs "Google" in front; "SM-S918B" needs "Samsung";
            // "OnePlus 9" already says who made it.
            model.startsWith(manufacturer, ignoreCase = true) -> model
            else -> "${manufacturer.replaceFirstChar { it.titlecase(Locale.ROOT) }} $model"
        }.ifEmpty { "Android" }
    }

    var tailscaleIp: String
        get() = prefs.getString(TAILSCALE_IP_KEY, "") ?: ""
        set(value) {
            prefs.edit().putString(TAILSCALE_IP_KEY, value.trim()).commit()
        }

    /** Whether the foreground service should keep sync alive with the app closed. */
    var keepAlive: Boolean
        get() = prefs.getBoolean(KEEP_ALIVE_KEY, true)
        set(value) {
            prefs.edit().putBoolean(KEEP_ALIVE_KEY, value).commit()
        }

    /** Auto-copy a received item straight to the system clipboard. */
    var autoApply: Boolean
        get() = prefs.getBoolean(AUTO_APPLY_KEY, true)
        set(value) {
            prefs.edit().putBoolean(AUTO_APPLY_KEY, value).commit()
        }

    /**
     * Sync whatever is on the clipboard the moment the app is opened.
     *
     * This is the closest Android allows to the Windows daemon's silent
     * background capture: reading the clipboard requires foreground focus
     * since Android 10, so "when the app comes forward" is the only automatic
     * moment available. Echo suppression (see ClipboardBridge.lastKnownHash)
     * keeps it from re-sending something that just arrived.
     */
    var autoCapture: Boolean
        get() = prefs.getBoolean(AUTO_CAPTURE_KEY, true)
        set(value) {
            prefs.edit().putBoolean(AUTO_CAPTURE_KEY, value).commit()
        }

    /** Take the color scheme from the wallpaper instead of ClipLink's own palette. */
    var dynamicColor: Boolean
        get() = prefs.getBoolean(DYNAMIC_COLOR_KEY, true)
        set(value) {
            prefs.edit().putBoolean(DYNAMIC_COLOR_KEY, value).commit()
        }

    private companion object {
        const val DEVICE_NAME_KEY = "device_name"
        const val TAILSCALE_IP_KEY = "tailscale_ip"
        const val KEEP_ALIVE_KEY = "keep_alive"
        const val AUTO_APPLY_KEY = "auto_apply"
        const val AUTO_CAPTURE_KEY = "auto_capture"
        const val DYNAMIC_COLOR_KEY = "dynamic_color"
    }
}
