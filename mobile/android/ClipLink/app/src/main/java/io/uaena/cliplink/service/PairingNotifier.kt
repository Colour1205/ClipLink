package io.uaena.cliplink.service

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import io.uaena.cliplink.MainActivity
import io.uaena.cliplink.R
import io.uaena.cliplink.engine.ClipLinkEngine
import io.uaena.cliplink.engine.PairingAlerts
import io.uaena.cliplink.engine.PairingRequest

/**
 * A pairing request as a notification, with Trust and Ignore on it, for when
 * the app is not in front. In front, the app shows a dialog over whatever
 * screen is open instead and this stays quiet.
 *
 * The two cases meet at the edges: a request that is still waiting when the
 * app goes to the background is posted then, and one is taken down the
 * moment the app comes back - the dialog takes over - or it is settled.
 *
 * Ignore, not Deny: nothing is remembered, so the device can ask again.
 * Blocking is a separate, deliberate action on the Devices tab.
 */
class PairingNotifier(
    private val app: Application,
    private val engine: ClipLinkEngine,
) : PairingAlerts {

    init {
        // A lifecycle observer has to be added on the main thread, and this is
        // built wherever the engine is first asked for.
        Handler(Looper.getMainLooper()).post {
            ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
                // Back in front: the dialog is showing it now.
                override fun onStart(owner: LifecycleOwner) = cancel(app)

                // Left with a request still open: nobody is looking at the
                // dialog, so say so. (Debounced by the platform, so a rotation
                // does not post and cancel one.)
                override fun onStop(owner: LifecycleOwner) {
                    engine.pairingRequest.value?.let(::post)
                }
            })
        }
    }

    override fun requested(request: PairingRequest) {
        if (isInFront()) return // the app's own dialog is showing it
        post(request)
    }

    override fun resolved() = cancel(app)

    private fun isInFront(): Boolean =
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)

    private fun post(request: PairingRequest) {
        val manager = app.getSystemService(NotificationManager::class.java)
        // Off in the system settings, or POST_NOTIFICATIONS denied: nothing
        // can be shown, and the request is still in the app when it is opened.
        if (!manager.areNotificationsEnabled()) return
        ensureChannel(manager)
        manager.notify(NOTIFICATION_ID, build(request))
    }

    private fun build(request: PairingRequest): Notification {
        val who = request.name ?: "A device with no name"
        // The name is whatever that device chose to call itself; the
        // fingerprint comes from its id, so the two are shown together.
        val detail = listOfNotNull(request.shortId, request.address).joinToString("  \u2022  ")

        val open = PendingIntent.getActivity(
            app,
            REQUEST_OPEN,
            Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_pairing)
            .setContentTitle("Pairing request")
            .setContentText("$who wants to pair with this phone")
            .setStyle(
                Notification.BigTextStyle().bigText(
                    "$who wants to pair with this phone. Only trust it if you are pairing it right now.\n$detail",
                ),
            )
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_EVENT)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            // Long enough to read and answer; short enough that it cannot sit in
            // the shade for a request whose device has long since given up.
            .setTimeoutAfter(TIMEOUT_MS)
            .addAction(
                // Trusting a device is a security decision: on a locked phone
                // this asks for the lock screen first.
                Notification.Action.Builder(null, "Trust", action(ACTION_TRUST, REQUEST_TRUST, request.deviceId))
                    .setAuthenticationRequired(true)
                    .build(),
            )
            .addAction(
                Notification.Action.Builder(null, "Ignore", action(ACTION_IGNORE, REQUEST_IGNORE, request.deviceId))
                    .build(),
            )
            .build()
    }

    /** A button's intent, naming the request it was posted for (see [PairingActionReceiver]). */
    private fun action(action: String, requestCode: Int, deviceId: String): PendingIntent =
        PendingIntent.getBroadcast(
            app,
            requestCode,
            Intent(app, PairingActionReceiver::class.java)
                .setAction(action)
                .putExtra(EXTRA_DEVICE_ID, deviceId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun ensureChannel(manager: NotificationManager) {
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                app.getString(R.string.pairing_channel_name),
                // HIGH: a request is time-sensitive and somebody is waiting on it.
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = app.getString(R.string.pairing_channel_description) },
        )
    }

    companion object {
        private const val CHANNEL_ID = "cliplink_pairing"
        private const val NOTIFICATION_ID = 2001
        private const val TIMEOUT_MS = 3 * 60 * 1000L

        private const val REQUEST_OPEN = 20
        private const val REQUEST_TRUST = 21
        private const val REQUEST_IGNORE = 22

        const val ACTION_TRUST = "io.uaena.cliplink.PAIRING_TRUST"
        const val ACTION_IGNORE = "io.uaena.cliplink.PAIRING_IGNORE"
        const val EXTRA_DEVICE_ID = "deviceId"

        fun cancel(context: Context) {
            context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        }
    }
}
