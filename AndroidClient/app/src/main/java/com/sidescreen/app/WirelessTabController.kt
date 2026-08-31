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
import kotlinx.coroutines.withContext

/**
 * Five-state UI machine for the Wireless tab on Android.
 *
 *   ① first-time → ② scanning (QRScannerActivity) → ③ connected
 *                                         ↘ ④ token mismatch / re-pair
 *   ⓹ permission denied permanently
 *
 * #46 replaces this private connection-looking state machine with the
 * authoritative application UI projection. Until then, keep security/storage
 * work out of the main-thread presentation path.
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
    ) -> Unit,
    private val onDisconnectRequested: () -> Unit,
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
        val repairReconnectButton: Button,
        val openSettingsButton: Button,
        val connectedMacName: TextView,
        val connectedMacIp: TextView,
        val connectingLabel: TextView,
        val connectingSubtitle: TextView,
        val cancelButton: Button,
        val idleMacName: TextView,
        val idleMacIp: TextView,
        val repairTitle: TextView,
        val repairMessage: TextView,
    )

    enum class State { FIRST_TIME, CONNECTING, CONNECTED, PAIRED_IDLE, REPAIR_NEEDED, PERM_DENIED }

    private var state: State = State.FIRST_TIME
    private var pendingPairingSave: Job? = null
    private var pendingStorageLoad: Job? = null
    private var lastKnownEntry: PairedHostStorage.Entry? = null

    fun bind() {
        views.scanButton.setOnClickListener { triggerScan() }
        views.rescanButton.setOnClickListener { triggerScan() }
        views.openSettingsButton.setOnClickListener { cameraPerm.openAppSettings() }
        views.forgetButton.setOnClickListener { forgetPairing() }
        views.idleForgetButton.setOnClickListener { forgetPairing() }
        views.reconnectButton.setOnClickListener { reconnect() }
        views.repairReconnectButton.setOnClickListener { reconnect() }
        views.cancelButton.setOnClickListener { onDisconnectRequested() }
    }

    private fun forgetPairing() {
        // A first-time KeyStore save runs on Dispatchers.IO. If the user taps
        // Forget while that write is still queued, cancellation must happen
        // before clear() or the background save could resurrect credentials.
        pendingPairingSave?.cancel()
        pendingPairingSave = null
        pendingStorageLoad?.cancel()
        pendingStorageLoad = null
        lastKnownEntry = null
        activity.lifecycleScope.launch(Dispatchers.IO) { storage.clear() }
        transition(State.FIRST_TIME)
    }

    /**
     * Called when the TCP stream goes down (user tapped Disconnect, network drop, etc).
     * Move the UI to a clean "paired but idle" state showing the Mac info + Reconnect button.
     */
    fun onStreamDisconnected() {
        android.util.Log.i("WirelessTabController", "onStreamDisconnected called, current state=$state")
        loadStoredEntry { entry ->
            if (entry == null) {
                transition(State.FIRST_TIME)
            } else {
                showPairedIdle(entry)
            }
        }
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
     * Called when the Wireless tab becomes visible. Decides initial state based on
     * cached host + camera permission state.
     *
     * No auto-connect: even when a cached pairing exists, the user must press
     * the Reconnect button to actually start a connection. #42 replaces this
     * with lifecycle-aware reconnect after the authoritative runtime lands.
     */
    fun show() {
        when {
            cameraPerm.isPermanentlyDenied() -> transition(State.PERM_DENIED)
            state == State.CONNECTING || state == State.CONNECTED -> Unit
            else -> loadStoredEntry { entry ->
                if (entry == null) {
                    transition(State.FIRST_TIME)
                } else {
                    showPairedIdle(entry)
                }
            }
        }
    }

    fun onScanResult(url: String) {
        val parsed = PairingURL.parse(url)
        if (parsed == null) {
            views.repairTitle.text = "⚠ Invalid QR code"
            views.repairMessage.text = "This is not a Side Screen pairing code. Scan the QR shown in the Mac app."
            views.repairReconnectButton.visibility = if (lastKnownEntry == null) View.GONE else View.VISIBLE
            transition(State.REPAIR_NEEDED)
            return
        }
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        val entry = PairedHostStorage.Entry(parsed.host, parsed.port, parsed.token, parsed.macName)
        lastKnownEntry = entry.defensiveCopy()

        // First-time AndroidKeyStore creation may involve secure hardware. Do
        // not make QR completion or connection startup wait on that disk/crypto
        // work. Cancel a previous pairing write so only the newest scanned host
        // may become persistent.
        pendingPairingSave?.cancel()
        pendingPairingSave = activity.lifecycleScope.launch(Dispatchers.IO) {
            if (!storage.save(entry)) {
                DiagLog.log("WirelessTabController", "Pairing credential could not be persisted securely")
            }
        }

        showConnecting("Connecting to ${parsed.macName}", "${parsed.host}:${parsed.port}")
        onConnectRequested(parsed.host, parsed.port, parsed.token, deviceName, parsed.macName)
    }

    fun onConnectError(
        error: StreamClient.WirelessConnectError,
        detail: String? = null,
    ) {
        val cached = lastKnownEntry
        when (error) {
            is StreamClient.WirelessConnectError.NetworkUnreachable -> {
                views.repairReconnectButton.visibility = if (cached == null) View.GONE else View.VISIBLE
                views.repairTitle.text = "⚠ Couldn't reach Mac"
                views.repairMessage.text =
                    if (cached != null) {
                        "No response from ${cached.macName} at ${cached.host}:${cached.port}.\n\n" +
                            "The Mac may have switched WiFi networks, changed its port, or is not " +
                            "running. Open SideScreen on the Mac and scan the new QR to re-pair."
                    } else {
                        "No response from your Mac. Make sure both devices are on the same WiFi " +
                            "and the Mac app is running, then scan the QR again."
                    }
                transition(State.REPAIR_NEEDED)
            }
            is StreamClient.WirelessConnectError.TokenRejected -> {
                views.repairReconnectButton.visibility = View.GONE
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
                views.repairReconnectButton.visibility = if (cached == null) View.GONE else View.VISIBLE
                views.repairTitle.text = "⚠ Connection error"
                val bridgeDetail = detail?.takeIf { it.isNotBlank() }
                views.repairMessage.text = buildString {
                    append("The Mac bridge rejected or closed the connection before streaming started.")
                    if (bridgeDetail != null) append("\n\n").append(bridgeDetail)
                    append("\n\nConfirm Side Screen is running on the Mac in Wireless mode, then tap Reconnect.")
                    append(" Scan a new QR only if the Mac pairing token or address changed.")
                }
                transition(State.REPAIR_NEEDED)
            }
        }
    }

    private fun showConnecting(
        title: String,
        subtitle: String,
    ) {
        views.connectingLabel.text = title
        views.connectingSubtitle.text = subtitle
        transition(State.CONNECTING)
    }

    fun onConnectSuccess() {
        val entry = lastKnownEntry
        if (entry != null) {
            views.repairReconnectButton.visibility = View.GONE
            views.connectedMacName.text = entry.macName
            views.connectedMacIp.text = "${entry.host}:${entry.port}"
            transition(State.CONNECTED)
            return
        }
        // A pairing read is still allowed as a fallback, but it stays off the
        // main thread. This path is only reachable after an unusual lifecycle
        // race where the cached entry was not populated yet.
        loadStoredEntry { loaded ->
            if (loaded == null) {
                transition(State.FIRST_TIME)
            } else {
                views.repairReconnectButton.visibility = View.GONE
                views.connectedMacName.text = loaded.macName
                views.connectedMacIp.text = "${loaded.host}:${loaded.port}"
                transition(State.CONNECTED)
            }
        }
    }

    private fun reconnect() {
        val cached = lastKnownEntry
        if (cached != null) {
            showConnecting("Reconnecting to ${cached.macName}", "${cached.host}:${cached.port}")
            attemptAutoConnect(cached)
            return
        }
        loadStoredEntry { entry ->
            if (entry == null) {
                transition(State.FIRST_TIME)
            } else {
                showConnecting("Reconnecting to ${entry.macName}", "${entry.host}:${entry.port}")
                attemptAutoConnect(entry)
            }
        }
    }

    private fun showPairedIdle(entry: PairedHostStorage.Entry) {
        lastKnownEntry = entry.defensiveCopy()
        views.idleMacName.text = entry.macName
        views.idleMacIp.text = "${entry.host}:${entry.port}"
        transition(State.PAIRED_IDLE)
    }

    /** AndroidKeyStore decrypts are intentionally kept off the main thread. */
    private fun loadStoredEntry(onLoaded: (PairedHostStorage.Entry?) -> Unit) {
        pendingStorageLoad?.cancel()
        pendingStorageLoad = activity.lifecycleScope.launch {
            val entry = withContext(Dispatchers.IO) { storage.load() }
            lastKnownEntry = entry?.defensiveCopy()
            onLoaded(entry)
        }
    }

    fun onCameraPermissionResult(granted: Boolean) {
        if (granted) {
            // Re-evaluate; user just granted, jump straight into scanner.
            launchScanner()
        } else if (cameraPerm.isPermanentlyDenied()) {
            transition(State.PERM_DENIED)
        }
        // else: stay in current state; user can tap Scan again to re-prompt.
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

    private fun attemptAutoConnect(entry: PairedHostStorage.Entry) {
        val deviceName = (android.os.Build.MODEL ?: "Android").take(64)
        onConnectRequested(entry.host, entry.port, entry.token, deviceName, entry.macName)
    }

    companion object {
        const val REQ_SCAN = 1001
        const val REQ_CAMERA = 1002
    }
}
