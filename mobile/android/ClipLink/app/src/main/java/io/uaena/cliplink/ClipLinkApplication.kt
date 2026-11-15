package io.uaena.cliplink

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import io.uaena.cliplink.engine.ClipLinkEngine
import io.uaena.cliplink.service.PairingNotifier

/**
 * The engine is process-scoped, not Activity- or ViewModel-scoped. Sync has
 * to survive the Activity being destroyed and recreated (a rotation, a theme
 * change), and the foreground service has to be looking at the exact same
 * connections the UI is.
 */
class ClipLinkApplication : Application() {

    private val lazyEngine = lazy {
        ClipLinkEngine(this).also { it.pairingAlerts = PairingNotifier(this, it) }
    }

    val engine: ClipLinkEngine by lazyEngine

    override fun onCreate() {
        super.onCreate()
        instance = this
        // The whole app leaving the screen, whichever of its activities was last:
        // the engine stops what keep-alive off says it shouldn't keep doing. Not
        // an engine made just for this - one that was never started has nothing running.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            // Coming up: the engine holds the multicast lock again while a screen
            // shows (see ClipLinkEngine.updateMulticastLock). Every screen makes the
            // engine in its onCreate, so it exists by now if it is going to.
            override fun onStart(owner: LifecycleOwner) {
                if (lazyEngine.isInitialized()) engine.onAppShown()
            }

            override fun onStop(owner: LifecycleOwner) {
                if (lazyEngine.isInitialized()) engine.onBackground()
            }
        })
    }

    companion object {
        lateinit var instance: ClipLinkApplication
            private set

        fun engine(): ClipLinkEngine = instance.engine
    }
}
