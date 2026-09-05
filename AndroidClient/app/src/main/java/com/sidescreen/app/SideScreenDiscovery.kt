package com.sidescreen.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
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
    private val mainHandler = Handler(Looper.getMainLooper())

    fun resolve(
        token: ByteArray,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        callback: (Endpoint?) -> Unit,
    ) {
        if (token.size != 32) {
            callback(null)
            return
        }
        val expectedName = WirelessServiceIdentity.nameForToken(token)
        val finished = AtomicBoolean(false)
        var discoveryStarted = false

        lateinit var discoveryListener: NsdManager.DiscoveryListener

        fun finish(endpoint: Endpoint?) {
            if (!finished.compareAndSet(false, true)) return
            if (discoveryStarted) {
                try {
                    manager.stopServiceDiscovery(discoveryListener)
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
                    if (finished.get()) return
                    if (serviceInfo.serviceName == expectedName) {
                        Log.i(TAG, "NSD matched ${serviceInfo.serviceName}; resolving")
                        try {
                            @Suppress("DEPRECATION")
                            manager.resolveService(serviceInfo, resolveListener)
                        } catch (e: Exception) {
                            Log.w(TAG, "NSD resolve launch failed: ${e.message}")
                            finish(null)
                        }
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

        mainHandler.postDelayed({ finish(null) }, timeoutMs.coerceIn(500L, 10_000L))
        try {
            manager.discoverServices(
                WirelessServiceIdentity.SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener,
            )
        } catch (e: Exception) {
            Log.w(TAG, "NSD discovery launch failed: ${e.message}")
            finish(null)
        }
    }

    private companion object {
        const val TAG = "SideScreenDiscovery"
        const val DEFAULT_TIMEOUT_MS = 3_000L
    }
}
