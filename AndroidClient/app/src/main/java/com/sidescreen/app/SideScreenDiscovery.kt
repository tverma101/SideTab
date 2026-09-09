package com.sidescreen.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.wifi.WifiManager
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Bounded Bonjour lookup used only as a reconnect fallback when the QR's
 * cached IP is stale. The service instance name is a SHA-256-derived identity
 * from the pairing token, so discovery never trusts a human-readable Mac name.
 */
class SideScreenDiscovery(context: Context) {
    data class Endpoint(val host: String, val port: Int)

    private val manager = context.applicationContext.getSystemService(NsdManager::class.java)
    private val connectivityManager =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val wifiManager = context.applicationContext.getSystemService(WifiManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val callbackExecutor = java.util.concurrent.Executor { command -> mainHandler.post(command) }

    fun resolve(
        token: ByteArray,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        network: Network? = null,
        callback: (Endpoint?) -> Unit,
    ) {
        if (token.size != 32) {
            callback(null)
            return
        }
        val expectedName = WirelessServiceIdentity.nameForToken(token)
        val finished = AtomicBoolean(false)
        val resolving = AtomicBoolean(false)
        var discoveryStarted = false
        var multicastLock: WifiManager.MulticastLock? = null

        lateinit var discoveryListener: NsdManager.DiscoveryListener
        lateinit var timeout: Runnable

        fun finish(endpoint: Endpoint?) {
            if (!finished.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeout)
            if (discoveryStarted) {
                try {
                    manager.stopServiceDiscovery(discoveryListener)
                } catch (_: Exception) {
                }
            }
            multicastLock?.let { lock ->
                try {
                    if (lock.isHeld) lock.release()
                } catch (_: Exception) {
                }
            }
            mainHandler.post { callback(endpoint) }
        }

        val resolveListener =
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "NSD resolve failed for ${serviceInfo.serviceName}: $errorCode")
                    finish(null)
                }

                @Suppress("DEPRECATION")
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.host?.hostAddress
                    val port = serviceInfo.port
                    if (host.isNullOrBlank() || port !in 1..65535) {
                        finish(null)
                    } else {
                        Log.i(TAG, "NSD recovered SideScreen endpoint $host:$port")
                        finish(Endpoint(host, port))
                    }
                }
            }

        discoveryListener =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {
                    discoveryStarted = true
                    Log.i(TAG, "NSD discovery started for $expectedName")
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    if (finished.get() || serviceInfo.serviceName != expectedName) return
                    if (!resolving.compareAndSet(false, true)) return
                    Log.i(TAG, "NSD matched ${serviceInfo.serviceName}; resolving")
                    try {
                        @Suppress("DEPRECATION")
                        manager.resolveService(serviceInfo, resolveListener)
                    } catch (e: Exception) {
                        Log.w(TAG, "NSD resolve launch failed: ${e.message}")
                        finish(null)
                    }
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

                override fun onDiscoveryStopped(serviceType: String) = Unit

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "NSD start failed: $errorCode")
                    try {
                        manager.stopServiceDiscovery(this)
                    } catch (_: Exception) {
                    }
                    finish(null)
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "NSD stop failed: $errorCode")
                }
            }

        timeout = Runnable { finish(null) }
        mainHandler.postDelayed(timeout, timeoutMs.coerceIn(500L, 10_000L))
        try {
            val wifiNetwork = network ?: activeWifiNetwork()
            if (wifiNetwork != null) {
                multicastLock = wifiManager?.createMulticastLock("SideScreenDiscovery")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && wifiNetwork != null) {
                Log.i(TAG, "NSD discovery bound to WiFi network $wifiNetwork")
                manager.discoverServices(
                    WirelessServiceIdentity.SERVICE_TYPE,
                    NsdManager.PROTOCOL_DNS_SD,
                    wifiNetwork,
                    callbackExecutor,
                    discoveryListener,
                )
            } else {
                @Suppress("DEPRECATION")
                manager.discoverServices(
                    WirelessServiceIdentity.SERVICE_TYPE,
                    NsdManager.PROTOCOL_DNS_SD,
                    discoveryListener,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "NSD discovery launch failed: ${e.message}")
            finish(null)
        }
    }

    private fun activeWifiNetwork(): Network? =
        connectivityManager?.allNetworks?.firstOrNull { network ->
            connectivityManager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }

    private companion object {
        const val TAG = "SideScreenDiscovery"
        const val DEFAULT_TIMEOUT_MS = 3_000L
    }
}
