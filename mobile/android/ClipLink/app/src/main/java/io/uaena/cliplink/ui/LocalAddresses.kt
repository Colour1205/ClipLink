package io.uaena.cliplink.ui

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * This device's own addresses ([read]), refreshed whenever the network
 * changes - Wi-Fi joined or left, a hotspot or a VPN such as Tailscale coming
 * up - and when the app comes back to the foreground. They used to be read
 * once, so the Me screen kept showing the addresses of a network the phone
 * had long left.
 *
 * The read happens off the main thread. A change is acted on a moment late:
 * the callback fires before the interface itself reflects it.
 */
@Composable
fun rememberLocalAddresses(read: () -> List<String>): List<String> {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val addresses = remember { mutableStateOf<List<String>>(emptyList()) }

    DisposableEffect(owner) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        var pending: Job? = null
        fun refresh(delayMs: Long) {
            pending?.cancel()
            pending = scope.launch {
                delay(delayMs)
                val now = read()
                if (now != addresses.value) addresses.value = now
            }
        }

        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh(SETTLE_MS)
            override fun onLost(network: Network) = refresh(SETTLE_MS)
            override fun onLinkPropertiesChanged(network: Network, linkProperties: android.net.LinkProperties) =
                refresh(SETTLE_MS)
        }
        // Every network, not just the default one: a VPN or a hotspot changes
        // the addresses without changing which network is the default.
        val registered = runCatching {
            manager?.registerNetworkCallback(NetworkRequest.Builder().build(), callback)
        }.isSuccess

        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh(0)
        }
        owner.lifecycle.addObserver(observer)
        refresh(0)

        onDispose {
            owner.lifecycle.removeObserver(observer)
            if (registered) runCatching { manager?.unregisterNetworkCallback(callback) }
            scope.cancel()
        }
    }
    return addresses.value
}

private const val SETTLE_MS = 400L
