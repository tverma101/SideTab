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

    fun interface Handle {
        fun cancel()
    }

    private val manager = context.applicationContext.getSystemService(NsdManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Start one bounded lookup and return ownership of it to the caller.
     * Calling [Handle.cancel] stops the underlying NSD search and suppresses
     * its completion callback. This matters when Forget / a new QR / a newer
     * reconnect supersedes an in-flight lookup: ignoring the old callback is
     * not enough because legacy NsdManager resolution can reject overlapping
     * discovery activity.
     */
    fun resolve(
        token: ByteArray,
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        callback: (Endpoint?) -> Unit,
    ): Handle {
        if (token.size != 32) {
            mainHandler.post { callback(null) }
            return Handle { }
        }
        val expectedName = WirelessServiceIdentity.nameForToken(token)
        val finished = AtomicBoolean(false)
        val resolving = AtomicBoolean(false)
        val resolveAttempts = AtomicInteger(0)
        val discoveryStarted = AtomicBoolean(false)

        lateinit var discoveryListener: NsdManager.DiscoveryListener
        lateinit var resolveListener: NsdManager.ResolveListener
        lateinit var timeout: Runnable

        fun stopDiscovery() {
            if (!discoveryStarted.compareAndSet(true, false)) return
            try {
                manager.stopServiceDiscovery(discoveryListener)
            } catch (e: Exception) {
                Log.w(TAG, "NSD stop failed during cleanup: ${e.message}")
            }
        }

        fun finish(
            endpoint: Endpoint?,
            deliverCallback: Boolean = true,
        ) {
            if (!finished.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeout)
            stopDiscovery()
            if (deliverCallback) {
                mainHandler.post { callback(endpoint) }
            }
        }

        fun resetBurstAfterFinalFailure(attempt: Int) {
            if (attempt >= MAX_RESOLVE_ATTEMPTS) {
                // Keep the overall discovery alive until its bounded timeout.
                // A later mDNS announcement starts a fresh short retry burst.
                resolveAttempts.set(0)
            }
        }

        fun launchResolve(serviceInfo: NsdServiceInfo) {
            if (finished.get()) return
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
                } else {
                    resetBurstAfterFinalFailure(attempt)
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
                    } else {
                        resetBurstAfterFinalFailure(attempt)
                    }
                }

                @Suppress("DEPRECATION")
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    resolving.set(false)
                    if (finished.get()) return
                    val host = serviceInfo.host?.hostAddress
                    val port = serviceInfo.port
                    if (host.isNullOrBlank() || port !in 1..65535) {
                        val attempt = resolveAttempts.get()
                        Log.w(TAG, "NSD resolved an unusable endpoint on attempt $attempt")
                        if (attempt < MAX_RESOLVE_ATTEMPTS) {
                            mainHandler.postDelayed({ launchResolve(serviceInfo) }, RESOLVE_RETRY_DELAY_MS)
                        } else {
                            resetBurstAfterFinalFailure(attempt)
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
                    if (finished.get()) {
                        // Cancellation can win the race with this asynchronous
                        // callback. Mark then stop so the abandoned discovery
                        // cannot remain registered until the platform timeout.
                        discoveryStarted.set(true)
                        stopDiscovery()
                        return
                    }
                    discoveryStarted.set(true)
                    Log.i(TAG, "NSD discovery started for $expectedName")
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    if (finished.get() || serviceInfo.serviceName != expectedName) return
                    launchResolve(serviceInfo)
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

                override fun onDiscoveryStopped(serviceType: String) {
                    discoveryStarted.set(false)
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "NSD start failed: $errorCode")
                    finish(null)
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "NSD stop failed: $errorCode")
                    discoveryStarted.set(false)
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

        return Handle { finish(null, deliverCallback = false) }
    }

    private companion object {
        const val TAG = "SideScreenDiscovery"
        const val DEFAULT_TIMEOUT_MS = 3_000L
        const val MAX_RESOLVE_ATTEMPTS = 3
        const val RESOLVE_RETRY_DELAY_MS = 150L
    }
}
