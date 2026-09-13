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
 *
 * Repair panel: when a pairing is still cached, Reconnect is primary and
 * Scan QR is secondary. Scan QR is primary only when re-pair is required
 * (token rejected) or there is no cached host.
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
        controlPort: Int?,
        alternateHosts: List<String>,
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
        val repairReconnectButton: Button,
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
    // Keep the last pairing in memory for the current app session. A secure
    // preference read can temporarily fail (for example while the Android
    // Keystore is recovering), but that must not turn a recoverable connection
    // error into a QR-only dead end.
    private var lastAttemptedEntry: PairedHostStorage.Entry? = null

    fun bind() {
        views.scanButton.setOnClickListener { triggerScan() }
        views.rescanButton.setOnClickListener { triggerScan() }
        views.openSettingsButton.setOnClickListener { cameraPerm.openAppSettings() }
        views.forgetButton.setOnClickListener {
            storage.clear()
            lastAttemptedEntry = null
            transition(State.FIRST_TIME)
        }
        views.idleForgetButton.setOnClickListener {
            storage.clear()
            lastAttemptedEntry = null
            transition(State.FIRST_TIME)
        }
        views.reconnectButton.setOnClickListener { startManualReconnect() }
        views.repairReconnectButton.setOnClickListener { startManualReconnect() }
    }

    private fun startManualReconnect() {
        val entry =
            storage.load() ?: lastAttemptedEntry ?: run {
                transition(State.FIRST_TIME)
                return
            }
        lastAttemptedEntry = copyEntry(entry)
        discoveryRecoveryArmed = true
        showConnecting("Reconnecting to ${entry.macName}", "${entry.host}:${entry.port}")
        attemptReconnect(entry)
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
            storage.load() ?: lastAttemptedEntry ?: run {
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
            state == State.CONNECTING || state == State.CONNECTED -> Unit
            else -> {
                val entry = storage.load() ?: lastAttemptedEntry
                if (entry == null) {
                    transition(State.FIRST_TIME)
                } else {
                    lastAttemptedEntry = copyEntry(entry)
                    showPairedIdle(entry)
                }
            }
        }
    }

    fun onScanResult(url: String) {
        val parsed = PairingURL.parse(url)
        if (parsed == null) {
            views.repairTitle.text = "⚠ Invalid QR code"
            views.repairMessage.text = "Scan the Side Screen QR shown in the Mac app."
            configureRepairActions(needsRePair = lastAttemptedEntry == null, entry = lastAttemptedEntry)
            transition(State.REPAIR_NEEDED)
            return
        }
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        val entry =
            PairedHostStorage.Entry(
                host = parsed.host,
                port = parsed.port,
                token = parsed.token,
                macName = parsed.macName,
                controlPortOverride = parsed.controlPortOverride,
            )
        lastAttemptedEntry = copyEntry(entry)
        try {
            storage.save(entry)
        } catch (e: Exception) {
            // The in-memory entry still supports this connection attempt and
            // its Reconnect action. A later launch can ask for a fresh QR.
            android.util.Log.w("WirelessTabController", "Couldn't persist pairing; keeping session recovery", e)
        }
        discoveryRecoveryArmed = true
        showConnecting("Connecting to ${parsed.macName}", "${parsed.host}:${parsed.port}")
        onConnectRequested(
            parsed.host,
            parsed.port,
            parsed.token,
            deviceName,
            parsed.macName,
            parsed.controlPortOverride,
            parsed.alternateHosts,
        )
    }

    fun onUserDisconnected() {
        discoveryRecoveryArmed = true
        discoveryRecoveryInFlight = false
        val entry = storage.load() ?: lastAttemptedEntry
        if (entry == null) {
            transition(State.FIRST_TIME)
        } else {
            lastAttemptedEntry = copyEntry(entry)
            showPairedIdle(entry)
        }
    }

    fun onConnectError(error: StreamClient.WirelessConnectError) {
        val cached = storage.load() ?: lastAttemptedEntry
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
                        "${cached.macName} reset its pairing token (for example, Reset Token was used or the Mac was reinstalled). Scan the new QR to pair again."
                    } else {
                        "The Mac reset its pairing token. Scan the new QR to pair again."
                    }
                configureRepairActions(needsRePair = true, entry = cached)
                transition(State.REPAIR_NEEDED)
            }

            is StreamClient.WirelessConnectError.ProtocolError -> {
                discoveryRecoveryArmed = false
                views.repairTitle.text = "⚠ Connection error"
                views.repairMessage.text =
                    if (cached != null) {
                        "Couldn't complete the secure handshake with ${cached.macName}. Tap Reconnect to try again, or scan a fresh QR only if the Mac was reset."
                    } else {
                        "Couldn't complete the secure handshake with the Mac. Scan the QR to pair."
                    }
                configureRepairActions(needsRePair = cached == null, entry = cached)
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
                showNetworkRepair(storage.load() ?: lastAttemptedEntry ?: entry)
                return@resolve
            }

            val updated =
                entry.copy(
                    host = endpoint.host,
                    port = endpoint.port,
                    alternateHosts = endpoint.alternateHosts,
                )
            lastAttemptedEntry = copyEntry(updated)
            try {
                storage.save(updated)
            } catch (e: Exception) {
                android.util.Log.w("WirelessTabController", "Couldn't persist recovered endpoint", e)
            }
            val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
            showConnecting("Reconnecting to ${updated.macName}", "${updated.host}:${updated.port}")
            onConnectRequested(
                updated.host,
                updated.port,
                updated.token,
                deviceName,
                updated.macName,
                updated.controlPortOverride,
                updated.alternateHosts,
            )
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
                    "then tap Reconnect. Scan QR only if you need to pair again."
            } else {
                "No response from your Mac. Make sure both devices are on the same WiFi " +
                    "and the Mac app is running, then scan the QR to pair."
            }
        configureRepairActions(needsRePair = cached == null, entry = cached)
        transition(State.REPAIR_NEEDED)
    }

    /**
     * When a pairing still exists, Reconnect is the primary recovery action.
     * Scan QR stays available as a secondary path, and becomes primary only
     * when re-pair is required or there is no cached host.
     */
    private fun configureRepairActions(
        needsRePair: Boolean,
        entry: PairedHostStorage.Entry?,
    ) {
        val actions = WirelessRecoveryActions.forState(entry != null, needsRePair)
        views.repairReconnectButton.visibility = if (actions.reconnectVisible) View.VISIBLE else View.GONE
        views.rescanButton.visibility = View.VISIBLE
        views.rescanButton.text = actions.rescanLabel
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

    private fun showPairedIdle(entry: PairedHostStorage.Entry) {
        views.idleMacName.text = entry.macName
        views.idleMacIp.text = "${entry.host}:${entry.port}"
        transition(State.PAIRED_IDLE)
    }

    private fun copyEntry(entry: PairedHostStorage.Entry): PairedHostStorage.Entry =
        entry.copy(token = entry.token.copyOf())

    fun onCameraPermissionResult(granted: Boolean) {
        if (granted) {
            launchScanner()
        } else if (cameraPerm.isPermanentlyDenied()) {
            transition(State.PERM_DENIED)
        }
    }

    fun close() = Unit

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
        onConnectRequested(
            entry.host,
            entry.port,
            entry.token,
            deviceName,
            entry.macName,
            entry.effectiveControlPort(),
            entry.alternateHosts,
        )
    }

    companion object {
        const val REQ_SCAN = 1001
        const val REQ_CAMERA = 1002
    }
}
