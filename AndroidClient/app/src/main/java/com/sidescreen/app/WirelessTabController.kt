package com.sidescreen.app

import android.app.Activity
import android.content.Intent
import android.net.Network
import android.os.Handler
import android.os.Looper
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
        network: Network?,
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
        val privateLinkButton: Button,
        val privateLinkStopButton: Button,
        val privateLinkDetails: TextView,
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
    private val privateLinkHandler = Handler(Looper.getMainLooper())
    private var privateLinkResolveInFlight = false
    private var privateLinkResolveDeadlineMs = 0L
    // Keep the last pairing in memory for the current app session. A secure
    // preference read can temporarily fail (for example while the Android
    // Keystore is recovering), but that must not turn a recoverable connection
    // error into a QR-only dead end.
    private var lastAttemptedEntry: PairedHostStorage.Entry? = null

    private lateinit var privateLink: PrivateLinkController

    init {
        privateLink =
            PrivateLinkController(
            activity,
            object : PrivateLinkController.Callbacks {
                override fun onPermissionRequired(permissions: Array<String>) {
                    views.privateLinkButton.isEnabled = true
                    views.repairTitle.text = "Private Link permission needed"
                    views.repairMessage.text =
                        "Allow Nearby Wi-Fi access so Side Screen can create a private local link. This link has no Internet route."
                    configureRepairActions(needsRePair = false, entry = storage.load() ?: lastAttemptedEntry)
                    transition(State.REPAIR_NEEDED)
                }

                override fun onReady(details: PrivateLinkController.Details) {
                    showPrivateLinkReady(details)
                }

                override fun onNetworkChanged(network: Network, tabletAddress: String?) {
                    if (privateLink.isRunning) {
                        val entry = storage.load() ?: lastAttemptedEntry
                        if (entry != null) {
                            schedulePrivateLinkResolve(entry, initialDelayMs = 250)
                        }
                    }
                }

                override fun onStopped() {
                    cancelPrivateLinkResolve()
                    views.privateLinkDetails.visibility = View.GONE
                    views.privateLinkStopButton.visibility = View.GONE
                    views.privateLinkButton.text = "USE PRIVATE LINK"
                }

                override fun onFailed(message: String) {
                    cancelPrivateLinkResolve()
                    views.privateLinkDetails.visibility = View.GONE
                    views.privateLinkStopButton.visibility = View.GONE
                    views.privateLinkButton.text = "USE PRIVATE LINK"
                    views.repairTitle.text = "⚠ Private Link unavailable"
                    views.repairMessage.text = message
                    configureRepairActions(needsRePair = false, entry = storage.load() ?: lastAttemptedEntry)
                    transition(State.REPAIR_NEEDED)
                }
                },
            )
    }

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
        views.privateLinkButton.setOnClickListener {
            if (privateLink.isRunning) {
                startPrivateLinkDiscovery()
            } else {
                startPrivateLink()
            }
        }
        views.privateLinkStopButton.setOnClickListener {
            privateLink.stop()
            showNetworkRepair(storage.load() ?: lastAttemptedEntry)
        }
    }

    private fun startPrivateLink() {
        views.repairTitle.text = "Starting Private Link…"
        views.repairMessage.text = "Creating a private Wi-Fi network on this tablet."
        views.privateLinkButton.isEnabled = false
        transition(State.REPAIR_NEEDED)
        privateLink.start(PrivateLinkController.PERMISSION_REQUEST_CODE)
    }

    private fun startPrivateLinkDiscovery() {
        val entry = storage.load() ?: lastAttemptedEntry
        if (entry == null) {
            views.repairTitle.text = "Pair once to use Private Link"
            views.repairMessage.text =
                "Join the Mac to the displayed Private Link, then scan the Side Screen QR once. Future reconnects will use the private link automatically."
            configureRepairActions(needsRePair = true, entry = null)
            transition(State.REPAIR_NEEDED)
            return
        }
        schedulePrivateLinkResolve(entry, initialDelayMs = 50)
    }

    private fun showPrivateLinkReady(details: PrivateLinkController.Details) {
        views.privateLinkButton.isEnabled = true
        views.privateLinkButton.text = "FIND MAC ON PRIVATE LINK"
        views.privateLinkStopButton.visibility = View.VISIBLE
        views.privateLinkDetails.visibility = View.VISIBLE
        views.privateLinkDetails.text =
            buildString {
                append("Wi-Fi name: ${details.ssid}\n")
                append("Password: ${details.passphrase ?: "none"}\n\n")
                append("On the Mac, join this Wi-Fi network. Keep SideScreen open here; the paired Mac will be found automatically.")
            }
        views.repairTitle.text = "Private Link ready"
        views.repairMessage.text =
            "This bypasses the current Wi-Fi's device isolation. It is local-only and does not provide Internet access."
        configureRepairActions(needsRePair = false, entry = storage.load() ?: lastAttemptedEntry)
        transition(State.REPAIR_NEEDED)
        (storage.load() ?: lastAttemptedEntry)?.let { schedulePrivateLinkResolve(it) }
    }

    private fun schedulePrivateLinkResolve(
        entry: PairedHostStorage.Entry,
        initialDelayMs: Long = 2_000L,
    ) {
        if (!privateLink.isRunning) return
        if (privateLinkResolveDeadlineMs == 0L) {
            privateLinkResolveDeadlineMs = System.currentTimeMillis() + PRIVATE_LINK_DISCOVERY_WINDOW_MS
        }
        privateLinkHandler.removeCallbacksAndMessages(PRIVATE_LINK_DISCOVERY_TOKEN)
        privateLinkHandler.postDelayed(
            { resolvePrivateLink(entry) },
            PRIVATE_LINK_DISCOVERY_TOKEN,
            initialDelayMs,
        )
    }

    private fun resolvePrivateLink(entry: PairedHostStorage.Entry) {
        if (!privateLink.isRunning || privateLinkResolveInFlight) return
        if (privateLinkResolveDeadlineMs != 0L && System.currentTimeMillis() > privateLinkResolveDeadlineMs) {
            privateLinkResolveDeadlineMs = 0L
            views.repairMessage.text =
                "Private Link is ready, but the Mac has not appeared yet. Join the Mac to the displayed Wi-Fi, then tap FIND MAC ON PRIVATE LINK."
            return
        }
        val network = privateLink.network
        if (network == null) {
            schedulePrivateLinkResolve(entry)
            return
        }
        privateLinkResolveInFlight = true
        views.repairMessage.text = "Looking for ${entry.macName} on the private link…"
        discovery.resolve(entry.token, timeoutMs = PRIVATE_LINK_DISCOVERY_TIMEOUT_MS, network = network) { endpoint ->
            privateLinkResolveInFlight = false
            if (!privateLink.isRunning) return@resolve
            if (endpoint == null) {
                schedulePrivateLinkResolve(entry, initialDelayMs = PRIVATE_LINK_DISCOVERY_RETRY_MS)
                return@resolve
            }

            privateLinkResolveDeadlineMs = 0L
            privateLinkHandler.removeCallbacksAndMessages(PRIVATE_LINK_DISCOVERY_TOKEN)
            val updated = entry.copy(host = endpoint.host, port = endpoint.port)
            lastAttemptedEntry = copyEntry(updated)
            try {
                storage.save(updated)
            } catch (e: Exception) {
                android.util.Log.w("WirelessTabController", "Couldn't persist Private Link endpoint", e)
            }
            views.repairMessage.text = "Found ${updated.macName} at ${updated.host}:${updated.port}. Connecting…"
            onConnectRequested(
                updated.host,
                updated.port,
                updated.token,
                (android.os.Build.MODEL ?: "Android").take(64),
                updated.macName,
                updated.controlPortOverride,
                privateLink.network,
            )
        }
    }

    private fun cancelPrivateLinkResolve() {
        privateLinkHandler.removeCallbacksAndMessages(PRIVATE_LINK_DISCOVERY_TOKEN)
        privateLinkResolveInFlight = false
        privateLinkResolveDeadlineMs = 0L
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

        if (privateLink.isRunning) {
            showPrivateLinkReadyIfAvailable(entry)
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
            privateLink.network,
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
                if (privateLink.isRunning && cached != null) {
                    showPrivateLinkReadyIfAvailable(cached)
                    return
                }
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

            val updated = entry.copy(host = endpoint.host, port = endpoint.port)
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
                privateLink.network,
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

    private fun showPrivateLinkReadyIfAvailable(entry: PairedHostStorage.Entry) {
        privateLink.currentDetails?.let(::showPrivateLinkReady)
            ?: run {
                views.privateLinkButton.isEnabled = true
                views.privateLinkButton.text = "FIND MAC ON PRIVATE LINK"
                views.privateLinkStopButton.visibility = View.VISIBLE
                views.repairTitle.text = "Private Link active"
                views.repairMessage.text =
                    "Join the Mac to the displayed Private Link, then tap FIND MAC ON PRIVATE LINK."
                configureRepairActions(needsRePair = false, entry = entry)
                transition(State.REPAIR_NEEDED)
                schedulePrivateLinkResolve(entry, initialDelayMs = 50)
            }
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
        views.privateLinkButton.visibility = if (needsRePair) View.GONE else View.VISIBLE
        if (!privateLink.isRunning) {
            views.privateLinkStopButton.visibility = View.GONE
            views.privateLinkDetails.visibility = View.GONE
            views.privateLinkButton.text = "USE PRIVATE LINK"
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

    fun onPrivateLinkPermissionResult(granted: Boolean) {
        if (granted) {
            privateLink.start(PrivateLinkController.PERMISSION_REQUEST_CODE)
        } else {
            views.privateLinkButton.isEnabled = true
            views.repairTitle.text = "Private Link permission denied"
            views.repairMessage.text =
                "Allow Nearby Wi-Fi access in Android Settings, then tap USE PRIVATE LINK again."
            transition(State.REPAIR_NEEDED)
        }
    }

    fun close() {
        cancelPrivateLinkResolve()
        privateLink.stop()
        privateLinkHandler.removeCallbacksAndMessages(null)
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
        onConnectRequested(
            entry.host,
            entry.port,
            entry.token,
            deviceName,
            entry.macName,
            entry.effectiveControlPort(),
            privateLink.network,
        )
    }

    companion object {
        const val REQ_SCAN = 1001
        const val REQ_CAMERA = 1002
        private const val PRIVATE_LINK_DISCOVERY_TIMEOUT_MS = 3_000L
        private const val PRIVATE_LINK_DISCOVERY_RETRY_MS = 3_000L
        private const val PRIVATE_LINK_DISCOVERY_WINDOW_MS = 120_000L
        private val PRIVATE_LINK_DISCOVERY_TOKEN = Any()
    }
}
