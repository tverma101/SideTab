package com.sidescreen.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper

/**
 * Small, bounded Bonjour/NSD resolver for a previously paired Mac. The QR
 * endpoint remains the first candidate; discovery is used after a transient
 * network failure so a DHCP address change does not require re-pairing.
 */
class WirelessHostDiscovery(context: Context) {
    data class Candidate(val host: String, val port: Int, val serviceName: String)

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val multicastLock =
        (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createMulticastLock("SideScreenBonjour")
    private val handler = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var completion: ((Candidate?) -> Unit)? = null
    private var resolving = false
    private var finished = false
    private var fallbackService: NsdServiceInfo? = null

    fun discover(preferredName: String, onResult: (Candidate?) -> Unit) {
        stop()
        completion = onResult
        finished = false
        resolving = false
        fallbackService = null
        multicastLock?.setReferenceCounted(false)
        runCatching { multicastLock?.acquire() }
        val normalizedPreferred = preferredName.trim()
        val discovery =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {
                    DiagLog.log("NSD", "Bonjour discovery started type=$serviceType")
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    if (finished || resolving) return
                    if (!serviceInfo.serviceType.trimEnd('.').equals(SERVICE_TYPE.trimEnd('.'), ignoreCase = true)) {
                        return
                    }
                    val nameMatches = serviceInfo.serviceName.equals(normalizedPreferred, ignoreCase = true)
                    if (nameMatches || normalizedPreferred.isBlank()) {
                        resolve(serviceInfo)
                    } else if (fallbackService == null) {
                        // Give an exact paired-name result a short window to
                        // arrive before resolving an unrelated SideScreen host.
                        fallbackService = serviceInfo
                        handler.postDelayed({
                            if (!finished && !resolving) {
                                fallbackService?.let { resolve(it) }
                            }
                        }, PREFERRED_NAME_WAIT_MS)
                    }
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

                override fun onDiscoveryStopped(serviceType: String) {
                    DiagLog.log("NSD", "Bonjour discovery stopped type=$serviceType")
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    DiagLog.log("NSD", "Bonjour discovery failed type=$serviceType code=$errorCode")
                    finish(null)
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    DiagLog.log("NSD", "Bonjour stop failed type=$serviceType code=$errorCode")
                }
            }
        listener = discovery
        handler.postDelayed({ finish(null) }, DISCOVERY_TIMEOUT_MS)
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (error: Exception) {
            DiagLog.log("NSD", "Bonjour discovery exception: ${error.message}")
            finish(null)
        }
    }

    fun stop() {
        finished = true
        handler.removeCallbacksAndMessages(null)
        listener?.let { current ->
            runCatching { nsd.stopServiceDiscovery(current) }
        }
        listener = null
        completion = null
        resolving = false
        fallbackService = null
        releaseMulticastLock()
    }

    private fun resolve(serviceInfo: NsdServiceInfo) {
        val current = listener ?: return
        resolving = true
        fallbackService = null
        nsd.resolveService(
            serviceInfo,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    resolving = false
                    DiagLog.log("NSD", "Bonjour resolve failed code=$errorCode name=${info.serviceName}")
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    if (listener !== current || finished) return
                    val host = info.host?.hostAddress
                    if (host.isNullOrBlank() || info.port <= 0) {
                        resolving = false
                        finish(null)
                        return
                    }
                    finish(Candidate(host, info.port, info.serviceName))
                }
            },
        )
    }

    private fun finish(result: Candidate?) {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        val callback = completion
        val current = listener
        listener = null
        completion = null
        resolving = false
        fallbackService = null
        current?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        releaseMulticastLock()
        callback?.invoke(result)
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) runCatching { lock.release() }
        }
    }

    companion object {
        const val SERVICE_TYPE = "_sidescreen._tcp."
        private const val DISCOVERY_TIMEOUT_MS = 4_000L
        private const val PREFERRED_NAME_WAIT_MS = 250L
    }
}
