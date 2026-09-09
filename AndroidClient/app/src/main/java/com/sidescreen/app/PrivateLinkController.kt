package com.sidescreen.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.LinkProperties
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.net.Inet4Address

/**
 * Owns the optional private local Wi-Fi link used when the current access
 * point isolates clients. The Android tablet becomes a local-only hotspot;
 * the Mac joins it manually, after which the normal token-authenticated
 * SideScreen stream is discovered on that private network.
 *
 * This is intentionally a local escape hatch, not a cloud relay. Android's
 * LocalOnlyHotspot has no Internet route, so the UI explains that the Mac
 * must join the displayed SSID before discovery can succeed.
 */
class PrivateLinkController(
    private val activity: Activity,
    private val callbacks: Callbacks,
) {
    data class Details(
        val ssid: String,
        val passphrase: String?,
        val tabletAddress: String?,
    )

    interface Callbacks {
        fun onPermissionRequired(permissions: Array<String>)
        fun onReady(details: Details)
        fun onNetworkChanged(network: Network, tabletAddress: String?)
        fun onStopped()
        fun onFailed(message: String)
    }

    private val context = activity.applicationContext
    private val wifiManager = context.getSystemService(WifiManager::class.java)
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    var network: Network? = null
        private set

    @Volatile
    var isRunning: Boolean = false
        private set

    @Volatile
    var currentDetails: Details? = null
        private set

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var details: Details? = null
    private var networkCallbackRegistered = false

    private data class HotspotCredentials(
        val ssid: String?,
        val passphrase: String?,
    )

    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                inspectNetwork(network)
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (isPrivateNetwork(capabilities)) {
                    inspectNetwork(network)
                }
            }

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                inspectNetwork(network, linkProperties)
            }

            override fun onLost(network: Network) {
                if (this@PrivateLinkController.network == network) {
                    this@PrivateLinkController.network = null
                    callbacks.onFailed("Private Link stopped before the Mac joined it.")
                }
            }
        }

    /** Starts the hotspot, requesting the one runtime permission Android needs. */
    fun start(permissionRequestCode: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            callbacks.onFailed("Private Link requires Android 8.0 or newer.")
            return
        }
        val missing = requiredPermissions().filterNot(::hasPermission).toTypedArray()
        if (missing.isNotEmpty()) {
            callbacks.onPermissionRequired(missing)
            ActivityCompat.requestPermissions(activity, missing, permissionRequestCode)
            return
        }
        if (isRunning) {
            details?.let(callbacks::onReady)
            network?.let { callbacks.onNetworkChanged(it, tabletAddress(it)) }
            return
        }

        registerNetworkCallback()
        try {
            wifiManager?.startLocalOnlyHotspot(hotspotCallback, mainHandler)
                ?: failAndUnregister("Wi-Fi is unavailable on this tablet.")
        } catch (security: SecurityException) {
            failAndUnregister("Android denied Nearby Wi-Fi access. Allow it in Settings, then try again.")
        } catch (error: Exception) {
            failAndUnregister("Private Link could not start: ${error.message ?: error.javaClass.simpleName}.")
        }
    }

    fun stop() {
        val hadState = isRunning || reservation != null || networkCallbackRegistered
        isRunning = false
        network = null
        details = null
        currentDetails = null
        reservation?.let {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        reservation = null
        unregisterNetworkCallback()
        if (hadState) callbacks.onStopped()
    }

    fun retryAfterPermission(permissionRequestCode: Int) {
        if (requiredPermissions().all(::hasPermission)) {
            start(permissionRequestCode)
        } else {
            callbacks.onFailed("Nearby Wi-Fi permission is still required for Private Link.")
        }
    }

    private val hotspotCallback =
        object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(newReservation: WifiManager.LocalOnlyHotspotReservation) {
                reservation = newReservation
                isRunning = true
                val credentials = hotspotCredentials(newReservation)
                val ssid = credentials?.ssid?.trim()?.trim('"').orEmpty()
                val passphrase = credentials?.passphrase?.takeIf { it.isNotBlank() }
                if (ssid.isBlank()) {
                    failAndUnregister("Android started Private Link without usable Wi-Fi credentials.")
                    return
                }
                details = Details(ssid, passphrase, network?.let(::tabletAddress))
                currentDetails = details
                // Some Samsung builds publish the local-only network before
                // delivering the callback registered above. Enumerate once
                // after onStarted so the exact swlan/ap network is still
                // captured instead of falling back to the campus Wi-Fi.
                connectivityManager?.allNetworks?.forEach(::inspectNetwork)
                DiagLog.log(
                    "PL",
                    "Private Link ready ssid=$ssid " +
                        "address=${details?.tabletAddress ?: "pending"}",
                )
                callbacks.onReady(details!!)
                network?.let { callbacks.onNetworkChanged(it, tabletAddress(it)) }
            }

            override fun onStopped() {
                isRunning = false
                reservation = null
                network = null
                details = null
                currentDetails = null
                unregisterNetworkCallback()
                callbacks.onStopped()
            }

            override fun onFailed(reason: Int) {
                val explanation =
                    when (reason) {
                        ERROR_INCOMPATIBLE_MODE ->
                            "Android cannot run Private Link while its current hotspot/Wi-Fi mode is active. Turn off system hotspot and try again."
                        ERROR_NO_CHANNEL -> "Android could not allocate a Wi-Fi channel for Private Link."
                        ERROR_TETHERING_DISALLOWED -> "This tablet or Wi-Fi policy disallows Private Link."
                        else -> "Android could not start Private Link on this tablet."
                    }
                failAndUnregister(explanation)
            }
        }

    private fun hotspotCredentials(
        activeReservation: WifiManager.LocalOnlyHotspotReservation,
    ): HotspotCredentials? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = activeReservation.softApConfiguration
            HotspotCredentials(config.ssid, config.passphrase)
        } else {
            @Suppress("DEPRECATION")
            activeReservation.wifiConfiguration?.let { config ->
                HotspotCredentials(config.SSID, config.preSharedKey)
            }
        }
    }

    private fun registerNetworkCallback() {
        if (networkCallbackRegistered) return
        try {
            val request =
                NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .build()
            connectivityManager?.registerNetworkCallback(request, networkCallback, mainHandler)
            networkCallbackRegistered = connectivityManager != null
        } catch (error: Exception) {
            DiagLog.log("PL", "Private Link network callback unavailable: ${error.message}")
        }
    }

    private fun unregisterNetworkCallback() {
        if (!networkCallbackRegistered) return
        try {
            connectivityManager?.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {
        }
        networkCallbackRegistered = false
    }

    private fun inspectNetwork(network: Network, suppliedLinkProperties: LinkProperties? = null) {
        val capabilities = connectivityManager?.getNetworkCapabilities(network) ?: return
        if (!isPrivateNetwork(capabilities)) return
        val linkProperties = suppliedLinkProperties ?: connectivityManager?.getLinkProperties(network)
        this.network = network
        val address = linkProperties?.let(::findIPv4Address)
        details = details?.copy(tabletAddress = address)
        currentDetails = details
        DiagLog.log("PL", "Private Link network available=$network address=${address ?: "pending"}")
        callbacks.onNetworkChanged(network, address)
    }

    private fun tabletAddress(network: Network): String? =
        connectivityManager?.getLinkProperties(network)?.let(::findIPv4Address)

    private fun findIPv4Address(linkProperties: LinkProperties): String? =
        linkProperties.linkAddresses
            .asSequence()
            .map { it.address }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { address -> !address.isLoopbackAddress && !address.isLinkLocalAddress }
            ?.hostAddress

    private fun isPrivateNetwork(capabilities: NetworkCapabilities): Boolean =
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            (
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_LOCAL_NETWORK))
            )

    private fun failAndUnregister(message: String) {
        isRunning = false
        reservation?.let {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        reservation = null
        network = null
        details = null
        currentDetails = null
        unregisterNetworkCallback()
        callbacks.onFailed(message)
    }

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        const val PERMISSION_REQUEST_CODE = 1003
    }
}
