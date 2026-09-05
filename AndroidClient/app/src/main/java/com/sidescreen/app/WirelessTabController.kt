package com.sidescreen.app

import android.app.Activity
import android.content.Intent
import android.view.View
import android.widget.Button
import android.widget.TextView

/**
 * Six-state UI machine for the Wireless tab on Android.
 *
 *   ① first-time → ② scanning (QRScannerActivity) → ③ connected
 *                                         ↘ ④ paired/idle
 *                                         ↘ ⑤ repair needed
 *   ⑥ permission denied permanently
 */
class WirelessTabController(
    private val activity: Activity,
    private val views: Views,
    private val storage: PairedHostStorage,
    private val cameraPerm: CameraPermissionManager,
    private val onConnectRequested: (
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        macName: String,
    ) -> Unit,
) {
    data class Views(
        val connecting: View,
        val firstTime: View,
        val connected: View,
        val pairedIdle: View,
        val repair: View,
        val permDenied: View,
        val scanButton: Button,
        val rescanButton: Button,
        val disconnectButton: Button,
        val forgetButton: Button,
        val reconnectButton: Button,
        val idleForgetButton: Button,
        val openSettingsButton: Button,
        val connectedMacName: TextView,
        val connectedMacIp: TextView,
        val connectingLabel: TextView,
        val connectingSubtitle: TextView,
        val idleMacName: TextView,
        val idleMacIp: TextView,
        val repairTitle: TextView,
        val repairMessage: TextView,
    )

    enum class State { FIRST_TIME, CONNECTING, CONNECTED, PAIRED_IDLE, REPAIR_NEEDED, PERM_DENIED }

    private var state: State = State.FIRST_TIME
    private val discovery = SideScreenDiscovery(activity.applicationContext)
    private var discoveryRecoveryArmed = true
    private var discoveryRecoveryInFlight = false

    fun bind() {
        views.scanButton.setOnClickListener { triggerScan() }
        views.rescanButton.setOnClickListener { triggerScan() }
        views.openSettingsButton.setOnClickListener { cameraPerm.openAppSettings() }
        views.forgetButton.setOnClickListener {
            storage.clear()
            transition(State.FIRST_TIME)
        }
        views.idleForgetButton.setOnClickListener {
            storage.clear()
            transition(State.FIRST_TIME)
        }
        views.reconnectButton.setOnClickListener {
            val entry =
                storage.load() ?: run {
                    transition(State.FIRST_TIME)
                    return@setOnClickListener
                }
            discoveryRecoveryArmed = true
            showConnecting("Reconnecting to ${entry.macName}", "${entry.host}:${entry.port}")
            attemptReconnect(entry)
        }
    }

    /**
     * Called only for an involuntary terminal stream loss. MainActivity bumps
     * its connection generation before an explicit user Disconnect, so that
     * callback is fenced out before it reaches this controller.
     *
     * Try the token-bound Bonjour identity immediately. This is also the
     * reliable handoff from StreamClient's direct-IP retry loop: MainActivity
     * clears its dead client on the false status callback, so the later thrown
     * NetworkUnreachable error is intentionally stale and may be ignored.
     */
    fun onStreamDisconnected() {
        android.util.Log.i(
            "WirelessTabController",
            "onStreamDisconnected called, current state=$state, storage entry exists=${storage.load() != null}",
        )
        val entry =
            storage.load() ?: run {
                transition(State.FIRST_TIME)
                return
            }

        if (tryDiscoveryRecovery(entry)) {
            return
        }
        showNetworkRepair(entry)
    }

    private fun transition(next: State) {
        android.util.Log.i("WirelessTabController", "transition $state → $next")
        state = next
        views.connecting.visibility = if (next == State.CONNECTING) View.VISIBLE else View.GONE
        views.firstTime.visibility = if (next == State.FIRST_TIME) View.VISIBLE else View.GONE
        views.connected.visibility = if (next == State.CONNECTED) View.VISIBLE else View.GONE
        views.pairedIdle.visibility = if (next == State.PAIRED_IDLE) View.VISIBLE else View.GONE
        views.repair.visibility = if (next == State.REPAIR_NEEDED) View.VISIBLE else View.GONE
        views.permDenied.visibility = if (next == State.PERM_DENIED) View.VISIBLE else View.GONE
    }

    /**
     * Called when the Wireless tab becomes visible. A cached pairing is shown
     * but not connected until the user asks, avoiding surprise connections
     * merely from switching tabs.
     */
    fun show() {
        when {
            cameraPerm.isPermanentlyDenied() -> transition(State.PERM_DENIED)
            storage.load() == null -> transition(State.FIRST_TIME)
            else -> {
                val entry = storage.load()!!
                views.idleMacName.text = entry.macName
                views.idleMacIp.text = "${entry.host}:${entry.port}"
                transition(State.PAIRED_IDLE)
            }
        }
    }

    fun onScanResult(url: String) {
        val parsed = PairingURL.parse(url) ?: return
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        storage.save(
            PairedHostStorage.Entry(
                host = parsed.host,
                port = parsed.port,
                token = parsed.token,
                macName = parsed.macName,
                controlPortOverride = parsed.controlPortOverride,
            ),
        )
        discoveryRecoveryArmed = true
        showConnecting("Connecting to ${parsed.macName}", "${parsed.host}:${parsed.port}")
        onConnectRequested(parsed.host, parsed.port, parsed.token, deviceName, parsed.macName)
    }

    fun onConnectError(error: StreamClient.WirelessConnectError) {
        val cached = storage.load()
        when (error) {
            is StreamClient.WirelessConnectError.NetworkUnreachable -> {
                if (cached != null && tryDiscoveryRecovery(cached)) {
                    return
                }
                showNetworkRepair(cached)
            }

            is StreamClient.WirelessConnectError.TokenRejected -> {
                discoveryRecoveryArmed = false
                views.repairTitle.text = "⚠ Re-pair required"
                views.repairMessage.text =
                    if (cached != null) {
                        "${cached.macName} reset its pairing token (e.g. Reset Token clicked, or " +
                            "reinstalled). Scan the new QR to pair again."
                    } else {
                        "The Mac reset its pairing token. Scan the new QR to pair again."
                    }
                transition(State.REPAIR_NEEDED)
            }

            is StreamClient.WirelessConnectError.ProtocolError -> {
                discoveryRecoveryArmed = false
                views.repairTitle.text = "⚠ Connection error"
                views.repairMessage.text = "Couldn't complete the secure handshake with the Mac. Scan the QR again."
                transition(State.REPAIR_NEEDED)
            }
        }
    }

    /**
     * One bounded Bonjour recovery attempt per connection action. This repairs
     * stale DHCP addresses without creating a discovery/reconnect loop.
     */
    private fun tryDiscoveryRecovery(entry: PairedHostStorage.Entry): Boolean {
        if (!discoveryRecoveryArmed || discoveryRecoveryInFlight) return false
        discoveryRecoveryArmed = false
        discoveryRecoveryInFlight = true
        showConnecting("Finding ${entry.macName}…", "Checking the local network")
        discovery.resolve(entry.token) { endpoint ->
            discoveryRecoveryInFlight = false
            if (endpoint == null) {
                showNetworkRepair(storage.load() ?: entry)
                return@resolve
            }

            val updated = entry.copy(host = endpoint.host, port = endpoint.port)
            try {
                storage.save(updated)
            } catch (e: Exception) {
                android.util.Log.w("WirelessTabController", "Couldn't persist recovered endpoint", e)
            }
            val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
            showConnecting("Reconnecting to ${updated.macName}", "${updated.host}:${updated.port}")
            onConnectRequested(updated.host, updated.port, updated.token, deviceName, updated.macName)
        }
        return true
    }

    private fun showNetworkRepair(cached: PairedHostStorage.Entry?) {
        views.repairTitle.text = "⚠ Couldn't reach Mac"
        views.repairMessage.text =
            if (cached != null) {
                "No response from ${cached.macName} at ${cached.host}:${cached.port}.\n\n" +
                    "SideScreen also searched the local network for the paired Mac but couldn't " +
                    "resolve a working endpoint. Make sure the Mac app is running on the same WiFi, " +
                    "then scan its QR again if needed."
            } else {
                "No response from your Mac. Make sure both devices are on the same WiFi " +
                    "and the Mac app is running, then scan the QR again."
            }
        transition(State.REPAIR_NEEDED)
    }

    private fun showConnecting(
        title: String,
        subtitle: String,
    ) {
        views.connectingLabel.text = title
        views.connectingSubtitle.text = subtitle
        transition(State.CONNECTING)
    }

    fun onConnectSuccess(
        macName: String,
        ip: String,
    ) {
        discoveryRecoveryArmed = true
        discoveryRecoveryInFlight = false
        views.connectedMacName.text = macName
        views.connectedMacIp.text = ip
        transition(State.CONNECTED)
    }

    fun onCameraPermissionResult(granted: Boolean) {
        if (granted) {
            launchScanner()
        } else if (cameraPerm.isPermanentlyDenied()) {
            transition(State.PERM_DENIED)
        }
    }

    private fun triggerScan() {
        if (cameraPerm.isPermanentlyDenied()) {
            transition(State.PERM_DENIED)
            return
        }
        if (!cameraPerm.isGranted()) {
            cameraPerm.request(REQ_CAMERA)
            return
        }
        launchScanner()
    }

    private fun launchScanner() {
        val intent = Intent(activity, QRScannerActivity::class.java)
        activity.startActivityForResult(intent, REQ_SCAN)
    }

    private fun attemptReconnect(entry: PairedHostStorage.Entry) {
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        onConnectRequested(entry.host, entry.port, entry.token, deviceName, entry.macName)
    }

    companion object {
        const val REQ_SCAN = 1001
        const val REQ_CAMERA = 1002
    }
}
