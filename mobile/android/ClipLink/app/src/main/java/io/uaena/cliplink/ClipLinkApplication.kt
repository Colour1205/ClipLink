package io.uaena.cliplink

import android.app.Application
import io.uaena.cliplink.engine.ClipLinkEngine
import io.uaena.cliplink.service.PairingNotifier

/**
 * The engine is process-scoped, not Activity- or ViewModel-scoped. Sync has
 * to survive the Activity being destroyed and recreated (a rotation, a theme
 * change), and the foreground service has to be looking at the exact same
 * connections the UI is.
 */
class ClipLinkApplication : Application() {

    val engine: ClipLinkEngine by lazy {
        ClipLinkEngine(this).also { it.pairingAlerts = PairingNotifier(this, it) }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        lateinit var instance: ClipLinkApplication
            private set

        fun engine(): ClipLinkEngine = instance.engine
    }
}
