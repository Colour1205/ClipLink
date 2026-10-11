package io.uaena.cliplink.engine

/**
 * Where a pairing request goes besides the app's own dialog. The engine says
 * one has arrived and, later, that it is settled; whoever implements this
 * decides whether anyone needs telling - the Android one posts a notification
 * (with Trust and Ignore buttons) when the app isn't in front, and does
 * nothing when it is, because the app is showing the dialog itself.
 *
 * A seam rather than a direct call so the engine stays free of notification
 * code and can be tested without a device.
 */
interface PairingAlerts {
    /** A request is waiting for a decision. */
    fun requested(request: PairingRequest)

    /** It was trusted, ignored, abandoned or blocked: whatever was shown for it should go. */
    fun resolved()
}
