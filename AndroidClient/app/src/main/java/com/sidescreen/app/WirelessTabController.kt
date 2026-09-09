package com.sidescreen.app

import android.content.Intent
import android.view.View
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

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
    private val activity: AppCompatActivity,
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
    private var pendingPairingSave: Job? = null

    fun bind() {
        views.scanButton.setOnClickListener { triggerScan() }
        views.rescanButton.setOnClickListener { triggerScan() }
        views.openSettingsButton.setOnClickListener { cameraPerm.openAppSettings() }
views.forgetButton.setOnClickListener { forgetPairing() }
        views.idleForgetButton.setOnClickListener { forgetPairing() }
        views.reconnectButton.setOnClickListener { startManualReconnect() }
        views.repairReconnectButton.setOnClickListener { startManualReconnect() }
    }

    private fun startManualReconnect() {
        discoveryRecoveryInFlight = false
        discovery.cancel()
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

    private fun forgetPairing() {
        cancelPendingPairingSave()
        // clear() is intentionally synchronous: Forget Pairing is a security
        // boundary and must durably invalidate storage before this action returns.
        // The in-memory session entry is dropped too: Forget Pairing must not
        // leave a live credential the UI can silently reconnect with.
        storage.clear()
        lastAttemptedEntry = null
        transition(State.FIRST_TIME)
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
     * merely from switching tabs. A permanently denied camera only blocks QR
     * re-pairing; a cached pairing still offers Reconnect.
     */
    fun show() {
        when {
            state == State.CONNECTING || state == State.CONNECTED -> Unit
            cameraPerm.isPermanentlyDenied() && (storage.load() ?: lastAttemptedEntry) == null ->
                transition(State.PERM_DENIED)
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
            views.repairTitle.text = activity.getString(R.string.wireless_qr_invalid_title)
            views.repairMessage.text = activity.getString(R.string.wireless_qr_invalid_message)
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
alternateHosts = parsed.alternateHosts,
            )
        lastAttemptedEntry = copyEntry(entry)

        // AndroidKeyStore initialization can involve secure hardware. Start the
        // live connection from the QR credential immediately and persist it on
        // IO; PairedHostStorage's mutation generation remains the final fence
        // against stale saves after a newer scan or Forget Pairing. The
        // in-memory entry still supports this connection attempt and its
        // Reconnect action even if persistence fails.
        persistPairing(entry)
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
        discovery.cancel()
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
                views.repairTitle.text = activity.getString(R.string.wireless_repair_token_title)
                views.repairMessage.text =
                    if (cached != null) {
                        activity.getString(R.string.wireless_repair_token_cached, cached.macName)
                    } else {
                        activity.getString(R.string.wireless_repair_token)
                    }
                configureRepairActions(needsRePair = true, entry = cached)
                transition(State.REPAIR_NEEDED)
            }

            is StreamClient.WirelessConnectError.ProtocolError -> {
                discoveryRecoveryArmed = false
                views.repairTitle.text = activity.getString(R.string.wireless_repair_protocol_title)
                views.repairMessage.text =
                    if (cached != null) {
                        activity.getString(R.string.wireless_repair_protocol_cached, cached.macName)
                    } else {
                        activity.getString(R.string.wireless_repair_protocol)
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
        showConnecting(
            activity.getString(R.string.wireless_finding_mac, entry.macName),
            activity.getString(R.string.wireless_checking_network),
        )
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
            persistPairing(updated)
            val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
            showConnecting(
                activity.getString(R.string.wireless_reconnecting_mac, updated.macName),
                activity.getString(R.string.wireless_endpoint, updated.host, updated.port),
            )
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

    @Synchronized
    private fun persistPairing(entry: PairedHostStorage.Entry) {
        pendingPairingSave?.cancel()
        pendingPairingSave =
            activity.lifecycleScope.launch(Dispatchers.IO) {
                try {
                    storage.save(entry)
                } catch (e: Exception) {
                    DiagLog.log(
                        "PAIR",
                        "Pairing persistence failed before secure storage: ${e.javaClass.simpleName}",
                    )
                }
            }
    }

    @Synchronized
    private fun cancelPendingPairingSave() {
        pendingPairingSave?.cancel()
        pendingPairingSave = null
    }

    private fun showNetworkRepair(cached: PairedHostStorage.Entry?) {
        views.repairTitle.text = activity.getString(R.string.wireless_repair_network_title)
        views.repairMessage.text =
            if (cached != null) {
                activity.getString(
                    R.string.wireless_repair_network_cached,
                    cached.macName,
                    cached.host,
                    cached.port,
                )
            } else {
                activity.getString(R.string.wireless_repair_network)
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
        views.idleMacIp.text = activity.getString(R.string.wireless_endpoint, entry.host, entry.port)
        transition(State.PAIRED_IDLE)
    }

    private fun copyEntry(entry: PairedHostStorage.Entry): PairedHostStorage.Entry =
        entry.copy(token = entry.token.copyOf())

    fun onCameraPermissionResult(granted: Boolean) {
        if (granted) {
            launchScanner()
            return
        }
        // Keep the current screen when a pairing exists: denial only blocks
        // scanning, not Reconnect. First-time users get the denial screen.
        if (cameraPerm.isPermanentlyDenied() &&
            (storage.load() ?: lastAttemptedEntry) == null
        ) {
            transition(State.PERM_DENIED)
        }
    }

    fun close() {
        discoveryRecoveryInFlight = false
        discovery.cancel()
    }

    private fun triggerScan() {
        if (cameraPerm.isPermanentlyDenied()) {
            // Denial blocks only re-pairing. With a cached pairing, repair
            // (with Reconnect) is more useful than the dead-end denial screen.
            if ((storage.load() ?: lastAttemptedEntry) == null) {
                transition(State.PERM_DENIED)
            } else {
                transition(State.REPAIR_NEEDED)
                configureRepairActions(needsRePair = true, entry = storage.load() ?: lastAttemptedEntry)
            }
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
