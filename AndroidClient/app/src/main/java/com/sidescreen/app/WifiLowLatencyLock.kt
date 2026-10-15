package com.sidescreen.app

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build

/**
 * SideTab's single Wi-Fi performance lock, driven by
 * [PowerPolicyDecision.wifiLowLatency]. Not reference counted: the power
 * policy is re-applied from many lifecycle callbacks, and each one states the
 * desired end state rather than incrementing it.
 */
internal class WifiLowLatencyLock(context: Context) {
    private val lock: WifiManager.WifiLock? =
        (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createWifiLock(lockMode(), "SideTab:wireless-stream")
            ?.apply { setReferenceCounted(false) }

    /** Acquire or release the lock. Returns true when the held state changed. */
    fun set(hold: Boolean): Boolean {
        val wifiLock = lock ?: return false
        if (hold == wifiLock.isHeld) return false
        if (hold) wifiLock.acquire() else wifiLock.release()
        return true
    }

    private companion object {
        // FULL_LOW_LATENCY (API 29+) disables 802.11 power save and asks the
        // chipset for its low-latency mode; HIGH_PERF is the older best effort.
        @Suppress("DEPRECATION")
        fun lockMode(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
    }
}
