package io.uaena.cliplink.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.uaena.cliplink.ClipLinkApplication

/**
 * The Trust and Ignore buttons on the pairing notification.
 *
 * Each button names the device its notification was posted for, and the
 * engine only acts if that is still the request waiting: a button that
 * outlived its request cannot answer whoever asked next.
 */
class PairingActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val deviceId = intent.getStringExtra(PairingNotifier.EXTRA_DEVICE_ID) ?: return
        val engine = ClipLinkApplication.engine()
        when (intent.action) {
            PairingNotifier.ACTION_TRUST -> engine.acceptPairing(expecting = deviceId)
            PairingNotifier.ACTION_IGNORE -> engine.rejectPairing(expecting = deviceId)
            else -> return
        }
        // Answering takes its own notification down. This covers the one case
        // it cannot: the app process was restarted since the notification was
        // posted, so there is no request left at all and nothing to clear it.
        if (engine.pairingRequest.value == null) PairingNotifier.cancel(context)
    }
}
