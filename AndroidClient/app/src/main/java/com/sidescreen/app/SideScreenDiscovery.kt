package com.sidescreen.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

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
        val resolving = AtomicBoolean(false)
        val resolveAttempts = AtomicInteger(0)
        var discoveryStarted = false

        lateinit var discoveryListener: NsdManager.DiscoveryListener
        lateinit var resolveListener: NsdManager.ResolveListener
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
            mainHandler.post { callback(endpoint) }
        }

        fun launchResolve(serviceInfo: NsdServiceInfo) {
            if (finished.get() || resolveAttempts.get() >= MAX_RESOLVE_ATTEMPTS) return
            if (!resolving.compareAndSet(false, true)) return
            val attempt = resolveAttempts.incrementAndGet()
            Log.i(TAG, "NSD resolving ${serviceInfo.serviceName} (attempt $attempt/$MAX_RESOLVE_ATTEMPTS)")
            try {
                @Suppress("DEPRECATION")
                manager.resolveService(serviceInfo, resolveListener)
            } catch (e: Exception) {
                resolving.set(false)
                Log.w(TAG, "NSD resolve launch failed on attempt $attempt: ${e.message}")
                if (attempt < MAX_RESOLVE_ATTEMPTS && !finished.get()) {
                    mainHandler.postDelayed({ launchResolve(serviceInfo) }, RESOLVE_RETRY_DELAY_MS)
                }
            }
        }

        resolveListener =
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    resolving.set(false)
                    val attempt = resolveAttempts.get()
                    Log.w(TAG, "NSD resolve failed for ${serviceInfo.serviceName} on attempt $attempt: $errorCode")
                    if (attempt < MAX_RESOLVE_ATTEMPTS && !finished.get()) {
                        mainHandler.postDelayed({ launchResolve(serviceInfo) }, RESOLVE_RETRY_DELAY_MS)
                    }
                    // Do not finish early after the final resolver failure.
                    // Discovery remains active until its bounded timeout, so a
                    // fresh service announcement still has a chance to arrive.
                }

                @Suppress("DEPRECATION")
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    resolving.set(false)
                    val host = serviceInfo.host?.hostAddress
                    val port = serviceInfo.port
                    if (host.isNullOrBlank() || port !in 1..65535) {
                        val attempt = resolveAttempts.get()
                        Log.w(TAG, "NSD resolved an unusable endpoint on attempt $attempt")
                        if (attempt < MAX_RESOLVE_ATTEMPTS && !finished.get()) {
                            mainHandler.postDelayed({ launchResolve(serviceInfo) }, RESOLVE_RETRY_DELAY_MS)
                        }
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
                    launchResolve(serviceInfo)
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
        const val MAX_RESOLVE_ATTEMPTS = 3
        const val RESOLVE_RETRY_DELAY_MS = 150L
    }
}
