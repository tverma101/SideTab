package com.sidescreen.app

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.Dialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.graphics.drawable.ColorDrawable
import android.hardware.usb.UsbManager
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Display
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.TextureView
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.constraintlayout.widget.ConstraintSet
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.google.android.material.slider.Slider
import com.google.android.material.switchmaterial.SwitchMaterial
import com.sidescreen.app.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.nio.ByteOrder

private fun mainDiag(msg: String) = DiagLog.log("MA", msg)

// Debug A/B hook action: adb shell am broadcast -a com.sidescreen.app.VSR_CMD
//   --ez enabled true --es mode sgsr [--ef sharpness 0.8] [--ef edge_threshold 0.03]
//   --ez enabled true --es mode cfl [--ef cfl_strength 0.15]
private const val VSR_CMD_ACTION = "com.sidescreen.app.VSR_CMD"
private const val LEGACY_E3_HOST = "10.77.0.1"
private const val LEGACY_E3_PORT = 54326

/**
 * Bounded wait for the Mac's codec selection on a device that cannot decode
 * HEVC. Long enough for a congested wireless connect, short enough that a
 * negotiation the host never sends cannot hold the screen black.
 */
private const val CODEC_NEGOTIATION_GRACE_MS = 1_500L

class MainActivity : AppCompatActivity() {
    private lateinit var wirelessController: WirelessTabController
    private val pairedHostStorage by lazy { PairedHostStorage(this) }
    private val cameraPerm by lazy { CameraPermissionManager(this) }
    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: PreferencesManager
    @Volatile private var videoDecoder: VideoDecoder? = null
    private var sgsrRenderer: SgsrRenderer? = null
    private var cflRenderer: CflRenderer? = null
    @Volatile private var streamClient: StreamClient? = null
    private var currentSurfaceHolder: SurfaceHolder? = null
    private var currentTextureSurface: Surface? = null
    private var decoderUsingTextureView = false
    private var displayWidth = 0 // 0 = no config received yet
    private var displayHeight = 0 // 0 = no config received yet
    private var displayRotation = 0 // 0, 90, 180, 270 degrees
    private var displayFlipHorizontal = false
    private var displayFlipVertical = false
    private var pingJob: kotlinx.coroutines.Job? = null

    // All callbacks from an old StreamClient become inert as soon as a newer
    // connect starts. Without this generation fence, a sender restart can
    // leave several clients reconnecting at once and starve the decoder.
    @Volatile private var activeConnectionGeneration = 0L

    /**
     * Fence for the asynchronous video-pipeline build. Every path that retires
     * the current pipeline (disconnect, new connection, surface recreation)
     * advances it, so a build that finishes afterwards is discarded instead of
     * publishing a decoder for a dead surface.
     */
    @Volatile private var videoPipelineGeneration = 0L

    /** Bounded wait for the Mac's codec selection on an AVC-only device. */
    @Volatile private var codecNegotiationJob: Job? = null
    private var displayConfigReceivedAtMs = 0L

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // Input prediction for low-latency gaming
    private val inputPredictor = InputPredictor()
    // S Pen contact is a drawing stroke, not a touch gesture. Keep its
    // pointer id across ACTION_MOVE/ACTION_POINTER_UP because Android may
    // reorder pointer indexes when a finger is also on the panel.
    private var activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
    private var regularTouchActive = false

    // Checklist status handler
    private val checklistHandler = Handler(Looper.getMainLooper())
    private var checklistRunnable: Runnable? = null
    private var isConnected = false // Track connection state to prevent checklist conflicts
    // A server status is only learned from an explicit stream attempt. Keeping
    // this as a local last-known value prevents the idle checklist from opening
    // a socket every few seconds and looking like a reconnect loop.
    private var macServerKnownAvailable: Boolean? = null

    // Auto-disconnect: if the app stays backgrounded past the configured
    // window (default 5 min; adb-tunable via
    //   adb shell settings put system sidescreen_auto_disconnect_secs <N>)
    // the session tears itself down. A killed process needs no timer — its
    // sockets die and the host's idle-sleep takes over.
    private var backgroundedAtMs = 0L
    private var autoDisconnectJob: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        DiagLog.init(applicationContext)
        prefs = PreferencesManager(this)

        // Allow rotation based on device sensor when not connected
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR

        // Enable edge-to-edge display (draw behind system bars and cutout)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Apply fullscreen mode immediately
        enableFullscreenMode()

        setupSurface()
        setupUI()
        setupDraggableOverlay()
        setupSettingsButton()
        restoreOverlayPosition()
        restoreSettingsButtonPosition()
        startChecklistUpdates()
        setupModeToggle()
        setupWirelessController()
        setupVsrCommandReceiver()

        // The Mac only re-runs codec negotiation for a client that advertises
        // inside a fixed window after connect, and a MediaCodecList walk can
        // take longer than that. Resolve the device's codec capabilities now,
        // off the main thread, so the first connect is a cache hit.
        lifecycleScope.launch(Dispatchers.Default) {
            CodecCapabilities.warmUp()
        }

        // Connections are user initiated. Keep the last-session preference
        // out of startup so a stale host, a sleeping Mac, or a transport
        // blip cannot make the tablet reconnect without a button press.
    }

    private fun setupModeToggle() {
        // Restore previous mode and reflect in toggle.
        val saved = prefs.connectionMode
        binding.modeToggleGroup.check(if (saved == ConnectionMode.WIRELESS) R.id.modeWireless else R.id.modeUSB)
        applyModeVisibility(saved)

        binding.modeToggleGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode = if (checkedId == R.id.modeWireless) ConnectionMode.WIRELESS else ConnectionMode.USB
            prefs.connectionMode = mode
            applyModeVisibility(mode)
            if (mode == ConnectionMode.WIRELESS) wirelessController.show()
        }
    }

    private fun applyModeVisibility(mode: ConnectionMode) {
        binding.usbModeContent.visibility = if (mode == ConnectionMode.USB) View.VISIBLE else View.GONE
        binding.wirelessModeContent.visibility = if (mode == ConnectionMode.WIRELESS) View.VISIBLE else View.GONE
        // USB checklist polls 127.0.0.1:port every 2s via adb-reverse to verify Mac
        // server reachability. While in Wireless mode that probe creates loopback
        // connections that fight the wireless session for the Mac's single client
        // slot — kicking the wireless client off seconds after it auths. Pause
        // checklist updates whenever Wireless is the active tab.
        if (mode == ConnectionMode.WIRELESS) {
            stopChecklistUpdates()
        } else {
            startChecklistUpdates()
        }
    }

    private fun setupWirelessController() {
        wirelessController =
            WirelessTabController(
                activity = this,
                views =
                    WirelessTabController.Views(
                        connecting = binding.wirelessConnecting,
                        firstTime = binding.wirelessFirstTime,
                        connected = binding.wirelessConnected,
                        pairedIdle = binding.wirelessPairedIdle,
                        repair = binding.wirelessTokenMismatch,
                        permDenied = binding.wirelessPermDenied,
                        scanButton = binding.wirelessScanButton,
                        rescanButton = binding.wirelessRescanButton,
                        disconnectButton = binding.wirelessDisconnectButton,
                        forgetButton = binding.wirelessForgetButton,
                        reconnectButton = binding.wirelessReconnectButton,
                        repairReconnectButton = binding.wirelessRepairReconnectButton,
                        idleForgetButton = binding.wirelessIdleForgetButton,
                        openSettingsButton = binding.wirelessOpenSettingsButton,
                        connectedMacName = binding.connectedMacName,
                        connectedMacIp = binding.connectedMacIp,
                        connectingLabel = binding.connectingLabel,
                        connectingSubtitle = binding.connectingSubtitle,
                        idleMacName = binding.idleMacName,
                        idleMacIp = binding.idleMacIp,
                        repairTitle = binding.repairTitle,
                        repairMessage = binding.repairMessage,
                    ),
                storage = pairedHostStorage,
                cameraPerm = cameraPerm,
                onConnectRequested = { host, port, token, deviceName, _, controlPort, alternateHosts ->
                    connectWireless(host, port, token, deviceName, controlPort, alternateHosts)
                },
            )
        wirelessController.bind()
        binding.wirelessDisconnectButton.setOnClickListener {
            disconnect()
            // The generation fence intentionally suppresses the stale client's
            // disconnected callback. Update the wireless state explicitly so a
            // user-initiated disconnect returns to the paired-idle screen with
            // its Reconnect action visible.
            wirelessController.onUserDisconnected()
        }
        if (prefs.connectionMode == ConnectionMode.WIRELESS) {
            wirelessController.show()
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: android.content.Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == WirelessTabController.REQ_SCAN && resultCode == RESULT_OK) {
            val url = data?.getStringExtra(QRScannerActivity.EXTRA_URL) ?: return
            wirelessController.onScanResult(url)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == WirelessTabController.REQ_CAMERA) {
            val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
            wirelessController.onCameraPermissionResult(granted)
        }
    }

    /** Keep the panel awake only while a live stream is visible. */
    private fun setDisplayKeepAwake(keepAwake: Boolean) {
        if (keepAwake) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    /**
     * Tell SurfaceFlinger the cadence of the source stream. On devices with a
     * seamless 60-Hz mode this can avoid running a 120-Hz panel for a 60-FPS
     * wireless stream; otherwise Android keeps the current mode and still
     * uses the hint for frame pacing. This is only a scheduling hint and does
     * not alter decoded pixels or frame rate.
     */
    private fun applyFrameRateHint() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        val wireless = streamClient?.isWirelessSession == true
        val connected = isConnected && streamClient != null && wireless
        if (!connected) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                currentSurfaceHolder?.surface?.takeIf { it.isValid }?.clearFrameRate()
                currentTextureSurface?.takeIf { it.isValid }?.clearFrameRate()
            }
            return
        }

        val requestedFps = WirelessFreshnessPolicy.TARGET_FRAME_RATE.toFloat()

        val surfaces = listOfNotNull(
            currentSurfaceHolder?.surface?.takeIf { it.isValid },
            currentTextureSurface?.takeIf { it.isValid },
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            surfaces.forEach { surface ->
                surface.setFrameRate(
                requestedFps,
                Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
                )
            }
        } else {
            surfaces.forEach { surface ->
                surface.setFrameRate(
                    requestedFps,
                    Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                )
            }
        }
        mainDiag("Frame-rate hint: ${"%.1f".format(requestedFps)}Hz, wireless=true")
    }

    /**
     * Enable fullscreen immersive mode
     * Uses modern WindowInsets API on Android R+ for better system compatibility
     * Also handles display cutout (notch) to use full screen area
     */
    private fun enableFullscreenMode() {
        // Ensure we draw behind the cutout
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            )
        }
    }

    /**
     * Disable fullscreen mode (when disconnected)
     */
    private fun disableFullscreenMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSurface() {
        binding.surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    mainDiag("surfaceCreated")
                    log("Surface created")
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag(
                        "surfaceChanged: ${width}x$height connected=$isConnected " +
                            "display=${displayWidth}x$displayHeight client=${streamClient != null}",
                    )
                    log("Surface changed: ${width}x$height")
                    currentSurfaceHolder = holder
                    applyFrameRateHint()
                    initializeDecoderForCurrentSurface()
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mainDiag("surfaceDestroyed")
                    log("Surface destroyed")
                    if (!decoderUsingTextureView) {
                        releaseVideoPipeline()
                    }
                    currentSurfaceHolder = null
                }
            },
        )

        binding.textureView.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("textureAvailable: ${width}x$height")
                    currentTextureSurface = Surface(surface)
                    applyFrameRateHint()
                    initializeDecoderForCurrentSurface()
                }

                override fun onSurfaceTextureSizeChanged(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("textureSizeChanged: ${width}x$height")
                    applyTextureTransform()
                }

                override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                    mainDiag("textureDestroyed")
                    if (decoderUsingTextureView) {
                        releaseVideoPipeline()
                    }
                    currentTextureSurface?.release()
                    currentTextureSurface = null
                    return true
                }

                override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
            }

        if (binding.textureView.isAvailable && currentTextureSurface == null) {
            binding.textureView.surfaceTexture?.let { currentTextureSurface = Surface(it) }
        }

        binding.surfaceView.setOnTouchListener { view, event ->
            handleTouch(view, event)
            true
        }
        binding.textureView.setOnTouchListener { view, event ->
            handleTouch(view, event)
            true
        }
        binding.surfaceView.setOnHoverListener { view, event ->
            handleStylusHover(view, event)
        }
        binding.textureView.setOnHoverListener { view, event ->
            handleStylusHover(view, event)
        }
    }

    private fun setupUI() {
        binding.connectButton.setOnClickListener {
            when (val result = UsbConnectionTarget.parse(
                binding.hostInput.text.toString(),
                binding.portInput.text.toString(),
            )) {
                is UsbConnectionTarget.ParseResult.Valid -> {
                    updateStatus(getString(R.string.connecting_status))
                    connect(result.target.host, result.target.port)
                }
                UsbConnectionTarget.ParseResult.InvalidHost -> showError(getString(R.string.usb_host_invalid))
                UsbConnectionTarget.ParseResult.InvalidPort -> showError(getString(R.string.usb_port_invalid))
            }
        }

        binding.disconnectButton.setOnClickListener {
            disconnect()
        }

        // Advanced settings toggle
        var advancedVisible = false
        binding.showAdvanced.setOnClickListener {
            advancedVisible = !advancedVisible
            binding.advancedSettings.visibility = if (advancedVisible) View.VISIBLE else View.GONE
            binding.showAdvanced.text = if (advancedVisible) "Hide Advanced Settings" else "Advanced Settings"
        }

        // Initial status
        updateStatus("Ready to connect")
    }

    private fun showError(message: String) {
        runOnUiThread {
            android.app.AlertDialog
                .Builder(this)
                .setTitle("Connection Error")
                .setMessage(message)
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun updateStatus(status: String) {
        runOnUiThread {
            binding.statusText.text = status
        }
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    private fun setupDraggableOverlay() {
        binding.streamStatusBarBinding.statusBar.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isDraggingOverlay = true
                    overlayDx = view.x - event.rawX
                    overlayDy = view.y - event.rawY
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (isDraggingOverlay) {
                        // Calculate new position
                        var newX = event.rawX + overlayDx
                        var newY = event.rawY + overlayDy

                        // Get screen bounds
                        val parent = view.parent as View
                        val maxX = parent.width - view.width.toFloat()
                        val maxY = parent.height - view.height.toFloat()

                        // Constrain to screen bounds
                        newX = newX.coerceIn(0f, maxX)
                        newY = newY.coerceIn(0f, maxY)

                        view
                            .animate()
                            .x(newX)
                            .y(newY)
                            .setDuration(0)
                            .start()
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (isDraggingOverlay) {
                        // Save position
                        prefs.overlayX = view.x
                        prefs.overlayY = view.y
                        isDraggingOverlay = false
                    }
                    true
                }

                else -> {
                    false
                }
            }
        }
    }

    private fun restoreOverlayPosition() {
        val x = prefs.overlayX
        val y = prefs.overlayY

        if (x >= 0 && y >= 0) {
            binding.streamStatusBarBinding.statusBar.post {
                binding.streamStatusBarBinding.statusBar.x = x
                binding.streamStatusBarBinding.statusBar.y = y
            }
        }

        // Apply opacity to both overlay and settings button
        val opacity = prefs.overlayOpacity
        updateOverlayOpacity(opacity)
        updateSettingsButtonOpacity(opacity)

        // Apply visibility
        updateOverlayVisibility(prefs.showStatsOverlay)
    }

    private fun updateOverlayOpacity(opacity: Float) {
        binding.streamStatusBarBinding.statusBar.alpha = opacity
    }

    private fun updateOverlayVisibility(show: Boolean) {
        if (streamClient != null && show) {
            binding.streamStatusBarBinding.statusBar.visibility = View.VISIBLE
            // Restore position when showing
            val x = prefs.overlayX
            val y = prefs.overlayY
            if (x >= 0 && y >= 0) {
                binding.streamStatusBarBinding.statusBar.post {
                    binding.streamStatusBarBinding.statusBar.x = x
                    binding.streamStatusBarBinding.statusBar.y = y
                }
            }
        } else {
            binding.streamStatusBarBinding.statusBar.visibility = View.GONE
        }
    }

    @SuppressLint("InflateParams", "SetTextI18n")
    private fun showSettingsDialog() {
        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(R.layout.dialog_settings)
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        val view = dialog.findViewById<View>(android.R.id.content)
        val showStatsSwitch = view.findViewById<SwitchMaterial>(R.id.showStatsSwitch)
        val hideSettingsSwitch = view.findViewById<SwitchMaterial>(R.id.hideSettingsSwitch)
        val opacitySlider = view.findViewById<Slider>(R.id.opacitySlider)
        val opacityValue = view.findViewById<TextView>(R.id.opacityValue)
        val resetButton = view.findViewById<View>(R.id.resetPositionButton)
        val resetSettingsBtn = view.findViewById<View>(R.id.resetSettingsButton)
        val disconnectButton = view.findViewById<View>(R.id.disconnectSettingsButton)
        val closeButton = view.findViewById<View>(R.id.closeButton)

        // Only show Disconnect when actually streaming. Otherwise the button is
        // a no-op and confuses users into clicking it twice.
        disconnectButton.visibility = if (isConnected) View.VISIBLE else View.GONE

        // Position buttons (8 directions)
        val cornerTopLeft = view.findViewById<MaterialButton>(R.id.cornerTopLeft)
        val cornerTopRight = view.findViewById<MaterialButton>(R.id.cornerTopRight)
        val cornerBottomLeft = view.findViewById<MaterialButton>(R.id.cornerBottomLeft)
        val cornerBottomRight = view.findViewById<MaterialButton>(R.id.cornerBottomRight)
        val positionTopCenter = view.findViewById<MaterialButton>(R.id.positionTopCenter)
        val positionBottomCenter = view.findViewById<MaterialButton>(R.id.positionBottomCenter)
        val positionCenterLeft = view.findViewById<MaterialButton>(R.id.positionCenterLeft)
        val positionCenterRight = view.findViewById<MaterialButton>(R.id.positionCenterRight)

        // Load current settings
        showStatsSwitch.isChecked = prefs.showStatsOverlay
        hideSettingsSwitch.isChecked = prefs.hideSettingsButton
        opacitySlider.value = prefs.overlayOpacity
        opacityValue.text = "${(prefs.overlayOpacity * 100).toInt()}%"

        // Highlight current position selection (8 positions)
        // 0=BottomRight, 1=BottomLeft, 2=TopRight, 3=TopLeft
        // 4=TopCenter, 5=BottomCenter, 6=CenterLeft, 7=CenterRight
        fun updatePositionSelection(selectedPosition: Int) {
            val buttons =
                listOf(
                    cornerBottomRight,
                    cornerBottomLeft,
                    cornerTopRight,
                    cornerTopLeft,
                    positionTopCenter,
                    positionBottomCenter,
                    positionCenterLeft,
                    positionCenterRight,
                )
            buttons.forEachIndexed { index, button ->
                if (index == selectedPosition) {
                    button.backgroundTintList =
                        android.content.res.ColorStateList
                            .valueOf(0x334CAF50)
                } else {
                    button.backgroundTintList = null
                }
            }
        }
        updatePositionSelection(prefs.settingsButtonCorner)

        // Setup listeners
        showStatsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.showStatsOverlay = isChecked
            updateOverlayVisibility(isChecked)
        }

        hideSettingsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.hideSettingsButton = isChecked
            if (isConnected) {
                applySettingsButtonVisibility()
            }
            if (isChecked) {
                android.widget.Toast
                    .makeText(
                        this,
                        "Settings icon hidden — use the back gesture to reveal it",
                        android.widget.Toast.LENGTH_LONG,
                    ).show()
            }
        }

        // ---- Video Super Resolution ----
        val vsrSwitch = view.findViewById<SwitchMaterial>(R.id.vsrSwitch)
        val vsrModeBridge = view.findViewById<MaterialButton>(R.id.vsrModeBridge)
        val vsrModeSgsr = view.findViewById<MaterialButton>(R.id.vsrModeSgsr)
        val vsrModeCas = view.findViewById<MaterialButton>(R.id.vsrModeCas)
        val vsrStatus = view.findViewById<TextView>(R.id.vsrStatus)

        vsrSwitch.isChecked = prefs.vsrEnabled
        vsrSwitch.isEnabled = supportsGles31()
        if (!supportsGles31()) {
            vsrStatus.text = "Requires OpenGL ES 3.1"
        }

        fun updateVsrModeSelection() {
            val current = SgsrRenderer.Mode.from(prefs.vsrMode)
            val map =
                mapOf(
                    vsrModeBridge to SgsrRenderer.Mode.BRIDGE_ONLY,
                    vsrModeSgsr to SgsrRenderer.Mode.SGSR1,
                    vsrModeCas to SgsrRenderer.Mode.CAS,
                )
            map.forEach { (btn, m) ->
                btn.backgroundTintList =
                    if (m == current) android.content.res.ColorStateList.valueOf(0x334CAF50) else null
            }
        }
        updateVsrModeSelection()

        vsrSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.vsrEnabled = isChecked
            restartVideoPath()
        }
        vsrModeBridge.setOnClickListener {
            prefs.vsrMode = SgsrRenderer.Mode.BRIDGE_ONLY.name
            updateVsrModeSelection()
            restartVideoPath()
        }
        vsrModeSgsr.setOnClickListener {
            prefs.vsrMode = SgsrRenderer.Mode.SGSR1.name
            updateVsrModeSelection()
            restartVideoPath()
        }
        vsrModeCas.setOnClickListener {
            prefs.vsrMode = SgsrRenderer.Mode.CAS.name
            updateVsrModeSelection()
            restartVideoPath()
        }

        // Live VSR param sliders — no restart needed (renderer recompiles shader on the fly)
        val vsrSharpnessSlider = view.findViewById<Slider>(R.id.vsrSharpnessSlider)
        val vsrSharpnessValue = view.findViewById<TextView>(R.id.vsrSharpnessValue)
        val vsrEdgeSlider = view.findViewById<Slider>(R.id.vsrEdgeSlider)
        val vsrEdgeValue = view.findViewById<TextView>(R.id.vsrEdgeValue)

        vsrSharpnessSlider.value = prefs.vsrSharpness
        vsrSharpnessValue.text = "%.2f".format(prefs.vsrSharpness)
        vsrEdgeSlider.value = prefs.vsrEdgeThreshold
        vsrEdgeValue.text = "%.3f".format(prefs.vsrEdgeThreshold)

        vsrSharpnessSlider.addOnChangeListener { _, value, _ ->
            prefs.vsrSharpness = value
            vsrSharpnessValue.text = "%.2f".format(value)
            sgsrRenderer?.setSharpness(value)
        }
        vsrEdgeSlider.addOnChangeListener { _, value, _ ->
            prefs.vsrEdgeThreshold = value
            vsrEdgeValue.text = "%.3f".format(value)
            sgsrRenderer?.setEdgeThreshold(value)
        }

        opacitySlider.addOnChangeListener { _, value, _ ->
            prefs.overlayOpacity = value
            updateOverlayOpacity(value)
            updateSettingsButtonOpacity(value)
            opacityValue.text = "${(value * 100).toInt()}%"
        }

        resetButton.setOnClickListener {
            prefs.overlayX = -1f
            prefs.overlayY = -1f
            // Use displayMetrics for reliable positioning
            val dm = resources.displayMetrics
            binding.streamStatusBarBinding.statusBar
                .animate()
                .x(dm.widthPixels - binding.streamStatusBarBinding.statusBar.width - 48f)
                .y(48f)
                .setDuration(300)
                .start()
        }

        // Position button listeners (8 directions)
        cornerBottomRight.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        cornerBottomLeft.setOnClickListener {
            prefs.settingsButtonCorner = 1
            updatePositionSelection(1)
            updateSettingsButtonPosition(1)
        }

        cornerTopRight.setOnClickListener {
            prefs.settingsButtonCorner = 2
            updatePositionSelection(2)
            updateSettingsButtonPosition(2)
        }

        cornerTopLeft.setOnClickListener {
            prefs.settingsButtonCorner = 3
            updatePositionSelection(3)
            updateSettingsButtonPosition(3)
        }

        positionTopCenter.setOnClickListener {
            prefs.settingsButtonCorner = 4
            updatePositionSelection(4)
            updateSettingsButtonPosition(4)
        }

        positionBottomCenter.setOnClickListener {
            prefs.settingsButtonCorner = 5
            updatePositionSelection(5)
            updateSettingsButtonPosition(5)
        }

        positionCenterLeft.setOnClickListener {
            prefs.settingsButtonCorner = 6
            updatePositionSelection(6)
            updateSettingsButtonPosition(6)
        }

        positionCenterRight.setOnClickListener {
            prefs.settingsButtonCorner = 7
            updatePositionSelection(7)
            updateSettingsButtonPosition(7)
        }

        resetSettingsBtn.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        disconnectButton.setOnClickListener {
            dialog.dismiss()
            disconnect()
        }

        closeButton.setOnClickListener {
            dialog.dismiss()
        }

        dialog.show()

        // Cap dialog height to 85% of screen so content scrolls on smaller screens / landscape
        dialog.window?.let { win ->
            val maxH = (resources.displayMetrics.heightPixels * 0.85).toInt()
            win.setLayout(WindowManager.LayoutParams.MATCH_PARENT, maxH)
        }
    }

    private fun updateSettingsButtonOpacity(opacity: Float) {
        binding.settingsButton.alpha = opacity
    }

    private fun setupSettingsButton() {
        // Simple click to show settings dialog
        // Position can be changed via corner buttons in settings
        binding.settingsButton.setOnClickListener {
            showSettingsDialog()
        }

        // Escape hatch for the hidden icon: the back gesture briefly reveals it
        // instead of leaving the app. Back is not forwarded to the Mac, so this
        // cannot conflict with streamed touch input.
        onBackPressedDispatcher.addCallback(
            this,
            object : androidx.activity.OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (isConnected && prefs.hideSettingsButton &&
                        binding.settingsButton.visibility != View.VISIBLE
                    ) {
                        revealSettingsButtonTemporarily()
                    } else {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            },
        )
    }

    /** Streaming-time visibility of the settings icon, honoring the hide preference. */
    private fun applySettingsButtonVisibility() {
        binding.settingsButton.visibility =
            if (prefs.hideSettingsButton) View.GONE else View.VISIBLE
    }

    private val revealHandler = Handler(Looper.getMainLooper())
    private val hideSettingsButtonRunnable =
        Runnable {
            if (isConnected && prefs.hideSettingsButton) {
                binding.settingsButton.visibility = View.GONE
            }
        }

    private fun revealSettingsButtonTemporarily() {
        binding.settingsButton.visibility = View.VISIBLE
        revealHandler.removeCallbacks(hideSettingsButtonRunnable)
        revealHandler.postDelayed(hideSettingsButtonRunnable, 5_000L)
    }

    private fun restoreSettingsButtonPosition() {
        updateSettingsButtonPosition(prefs.settingsButtonCorner)
    }

    /**
     * Use ConstraintSet to position settings button - most reliable method
     * Works correctly with orientation changes
     * Supports 8 positions: 4 corners + 4 edges
     */
    private fun updateSettingsButtonPosition(position: Int) {
        val constraintLayout = binding.root
        val constraintSet = ConstraintSet()
        constraintSet.clone(constraintLayout)

        val buttonId = binding.settingsButton.id
        val marginDp = (24 * resources.displayMetrics.density).toInt()

        // Clear all constraints first
        constraintSet.clear(buttonId, ConstraintSet.TOP)
        constraintSet.clear(buttonId, ConstraintSet.BOTTOM)
        constraintSet.clear(buttonId, ConstraintSet.START)
        constraintSet.clear(buttonId, ConstraintSet.END)

        when (position) {
            0 -> { // Bottom Right (default)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            1 -> { // Bottom Left
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            2 -> { // Top Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            3 -> { // Top Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            4 -> { // Top Center
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            5 -> { // Bottom Center
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            6 -> { // Center Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            7 -> { // Center Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            else -> { // Default to bottom right
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }
        }

        // Reset any absolute positioning that might have been set
        binding.settingsButton.translationX = 0f
        binding.settingsButton.translationY = 0f

        constraintSet.applyTo(constraintLayout)
    }

    /**
     * Display config from a new Mac arrives AFTER codecSelected, so a missing
     * negotiation means the Mac never selected a codec: either its app predates
     * H.264 support, or this client missed the host's post-connect window.
     * Either way the client can still stream H.264, so say what is happening
     * instead of leaving a silent black screen.
     */
    private fun warnIfAvcOnlyWithoutNegotiation() {
        if (!CodecCapabilities.hasHevcDecoder && streamClient?.codecNegotiated != true) {
            mainDiag("AVC-only device but Mac did not negotiate codec (old Mac app, or the negotiation window was missed)")
            runOnUiThread {
                updateStatus("This device has no HEVC decoder and the Mac selected no codec - trying H.264")
            }
        }
    }

    /**
     * How long an AVC-only device waits for the Mac's codecSelected before
     * building the H.264 decoder itself. The host's negotiation is single-shot:
     * it arms a fixed timer after connect and only a later capability advert
     * re-runs it, so codecSelected can legitimately never arrive. Waiting for it
     * forever is a permanent black screen, so the wait is bounded.
     */
    private fun codecNegotiationGraceMs(): Long {
        val configuredAt = displayConfigReceivedAtMs
        if (configuredAt <= 0L) return 0L
        return (configuredAt + CODEC_NEGOTIATION_GRACE_MS) - System.currentTimeMillis()
    }

    private fun awaitCodecNegotiation() {
        val remainingMs = codecNegotiationGraceMs()
        if (remainingMs <= 0L) {
            mainDiag("AVC-only device with no codec negotiation — using H.264")
            warnIfAvcOnlyWithoutNegotiation()
            return
        }
        codecNegotiationJob?.cancel()
        codecNegotiationJob = lifecycleScope.launch {
            delay(remainingMs)
            if (streamClient?.codecNegotiated != true &&
                !CodecCapabilities.hasHevcDecoder &&
                videoDecoder == null
            ) {
                mainDiag("codecSelected never arrived after ${CODEC_NEGOTIATION_GRACE_MS}ms — initializing H.264")
                initializeDecoderForCurrentSurface()
            }
        }
    }

    /**
     * Recreate the decoder when the negotiated stream codec doesn't match the
     * decoder's mime. Display config and codecSelected can arrive in either
     * order on reconnect; without this, a decoder created with the default
     * HEVC mime keeps consuming the H.264 stream and never outputs a frame —
     * a permanent black screen on AVC-only devices (e.g. Unisoc tablets).
     */
    private fun onStreamCodecSelected(isHevc: Boolean) {
        val expectedMime =
            if (isHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        codecNegotiationJob?.cancel()
        codecNegotiationJob = null
        runOnUiThread {
            val dec = videoDecoder
            when {
                dec == null -> {
                    mainDiag("Codec selected ($expectedMime) — initializing deferred decoder")
                    initializeDecoderForCurrentSurface()
                }
                dec.mime != expectedMime -> {
                    mainDiag("Stream codec is $expectedMime but decoder is ${dec.mime} — recreating")
                    dec.release()
                    videoDecoder = null
                    initializeDecoderForCurrentSurface()
                }
            }
        }
    }

    private fun shouldUseTextureView(): Boolean = displayFlipHorizontal || displayFlipVertical

    private fun supportsGles31(): Boolean {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.deviceConfigurationInfo.reqGlEsVersion >= 0x30001
    }

    /** Recreate the video path (decoder + optional VSR renderer) with current prefs. */
    private fun restartVideoPath() {
        if (!isConnected) return
        releaseVideoPipeline()
        applyDirectPixelMapping(displayWidth, displayHeight)
        initializeDecoderForCurrentSurface()
    }

    /** Release codec and post-process resources before replacing their surface. */
    private fun releaseVideoPipeline() {
        videoPipelineGeneration += 1L
        codecNegotiationJob?.cancel()
        codecNegotiationJob = null
        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
        decoderUsingTextureView = false
    }

    /**
     * Preserve a one-stream-pixel-to-one-panel-pixel mapping for near-native
     * direct streams. Stretching a 98-99% stream across the whole panel makes
     * SurfaceFlinger resample every pixel and visibly softens text. Centering
     * the surface at its encoded size leaves only a tiny black border while
     * keeping the decoded image pixel exact. Lower-resolution streams and VSR
     * modes continue filling the panel as before.
     */
    private fun applyDirectPixelMapping(
        streamWidth: Int,
        streamHeight: Int,
    ) {
        binding.surfaceView.post {
            val panelWidth = binding.root.width
            val panelHeight = binding.root.height
            val nearNative =
                !prefs.vsrEnabled &&
                    !shouldUseTextureView() &&
                    streamWidth in 1..panelWidth &&
                    streamHeight in 1..panelHeight &&
                    streamWidth.toFloat() / panelWidth >= DIRECT_PIXEL_MIN_SCALE &&
                    streamHeight.toFloat() / panelHeight >= DIRECT_PIXEL_MIN_SCALE
            val targetWidth = if (nearNative) streamWidth else 0
            val targetHeight = if (nearNative) streamHeight else 0
            val params = binding.surfaceView.layoutParams as ConstraintLayout.LayoutParams
            if (params.width != targetWidth || params.height != targetHeight) {
                params.width = targetWidth
                params.height = targetHeight
                binding.surfaceView.layoutParams = params
            }
            mainDiag(
                "Surface mapping: ${if (nearNative) "1:1" else "fill"} " +
                    "stream=${streamWidth}x$streamHeight panel=${panelWidth}x$panelHeight",
            )
        }
    }

    private var vsrCmdReceiver: BroadcastReceiver? = null

    /** Debug-only A/B hook; never registers an externally reachable receiver in release builds. */
    private fun setupVsrCommandReceiver() {
        if (!BuildConfig.DEBUG || vsrCmdReceiver != null) return
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    context: Context?,
                    intent: Intent?,
                ) {
                    val i = intent ?: return
                    if (i.action != VSR_CMD_ACTION) return
                    val mode = i.getStringExtra("mode")
                    val enabled =
                        if (i.hasExtra("enabled")) {
                            i.getBooleanExtra("enabled", false)
                        } else {
                            mode != null || prefs.vsrEnabled
                        }
                    mode?.let { prefs.vsrMode = it }
                    i.getFloatExtra("sharpness", -1f).takeIf { it >= 0f }?.let { prefs.vsrSharpness = it }
                    i.getFloatExtra("cfl_strength", -1f).takeIf { it >= 0f }?.let { prefs.cflStrength = it }
                    i.getFloatExtra("edge_threshold", -1f).takeIf { it >= 0f }?.let { prefs.vsrEdgeThreshold = it }
                    prefs.vsrEnabled = enabled
                    mainDiag("VSR_CMD: enabled=$enabled mode=${prefs.vsrMode}")
                    restartVideoPath()
                }
            }
        val filter = IntentFilter(VSR_CMD_ACTION)
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_EXPORTED)
        vsrCmdReceiver = receiver
    }

    private fun activeVideoSurface(): Pair<Surface, Boolean>? {
        return if (shouldUseTextureView()) {
            currentTextureSurface?.takeIf { it.isValid }?.let { it to true }
        } else {
            currentSurfaceHolder?.surface?.takeIf { it.isValid }?.let { it to false }
        }
    }

    /**
     * Main-thread entry point. Everything expensive — MediaCodec construction
     * (which enumerates the codec list) and the VSR renderers' EGL setup — runs
     * on a background dispatcher, because this is reached from surfaceChanged,
     * onDisplaySize, onStreamCodecSelected, onStart and the settings toggles,
     * and each of those used to stall the UI thread for hundreds of
     * milliseconds. The result is published back here behind the
     * videoPipelineGeneration fence, so a build whose pipeline was retired
     * while it ran is released instead of published.
     */
    private fun initializeDecoderForCurrentSurface() {
        if (displayWidth <= 0 || displayHeight <= 0) {
            mainDiag("initializeDecoder skipped — no display config yet")
            return
        }
        // AVC-only device: an HEVC decoder can never decode the H.264 stream
        // the Mac will send, so wait for codecSelected — but only for a bounded
        // time. The host arms its negotiation once after connect and a client
        // that misses the window is never told which codec to expect, so
        // waiting for that message forever is a permanent black screen.
        if (!CodecCapabilities.hasHevcDecoder && streamClient?.codecNegotiated != true) {
            val graceRemainingMs = codecNegotiationGraceMs()
            if (graceRemainingMs > 0L) {
                mainDiag("initializeDecoder deferred — AVC-only device awaiting codec negotiation (${graceRemainingMs}ms left)")
                awaitCodecNegotiation()
                return
            }
            mainDiag("initializeDecoder proceeding with H.264 — the Mac never sent codecSelected")
        }

        val (surface, useTextureView) =
            activeVideoSurface() ?: run {
                val kind = if (shouldUseTextureView()) "TextureView" else "SurfaceView"
                mainDiag("initializeDecoder skipped — no valid $kind surface")
                return
            }

        val reusable = videoDecoder
        if (reusable != null && decoderUsingTextureView == useTextureView && sgsrRenderer == null && cflRenderer == null) {
            if (!reusable.needsResolutionUpdate(displayWidth, displayHeight)) return
            val decoder = reusable
            val width = displayWidth
            val height = displayHeight
            val generation = videoPipelineGeneration
            lifecycleScope.launch(Dispatchers.Default) {
                decoder.updateResolution(width, height)
                if (generation != videoPipelineGeneration) return@launch
                mainDiag("Decoder resolution updated to ${width}x$height")
            }
            return
        }

        releaseVideoPipeline()
        decoderUsingTextureView = useTextureView

        val generation = videoPipelineGeneration
        val request =
            VideoPipelineRequest(
                surface = surface,
                surfaceIsValid = surface.isValid,
                width = displayWidth,
                height = displayHeight,
                display =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        display
                    } else {
                        @Suppress("DEPRECATION")
                        windowManager.defaultDisplay
                    },
                mime =
                    if (streamClient?.streamCodecIsHevc == false) {
                        MediaFormat.MIMETYPE_VIDEO_AVC
                    } else {
                        MediaFormat.MIMETYPE_VIDEO_HEVC
                    },
                useTextureView = useTextureView,
                gles31 = supportsGles31(),
                vsrEnabled = prefs.vsrEnabled,
                vsrMode = prefs.vsrMode,
                cflStrength = prefs.cflStrength,
                vsrSharpness = prefs.vsrSharpness,
                vsrEdgeThreshold = prefs.vsrEdgeThreshold,
                wirelessSession = streamClient?.isWirelessSession == true,
            )

        mainDiag(
            "initializeDecoder called, surface=$surface, valid=${request.surfaceIsValid}, " +
                "res=${request.width}x${request.height}, texture=$useTextureView",
        )

        lifecycleScope.launch(Dispatchers.Default) {
            val startedNs = System.nanoTime()
            val pipeline =
                try {
                    buildVideoPipeline(request)
                } catch (e: Exception) {
                    mainDiag("Decoder init FAILED: ${e.message}")
                    log("❌ Failed to initialize decoder: ${e.message}")
                    withContext(Dispatchers.Main) {
                        if (generation != videoPipelineGeneration) return@withContext
                        updateStatus("Video decoder failed: ${e.message}")
                    }
                    return@launch
                }
            mainDiag(
                "Decoder pipeline built in ${"%.0f".format((System.nanoTime() - startedNs) / 1e6)}ms " +
                    "(mime=${request.mime}, bufferOutput=${pipeline.decoder.bufferOutputMode})",
            )
            var handedOver = false
            try {
                withContext(Dispatchers.Main) {
                    if (generation != videoPipelineGeneration) {
                        mainDiag("Discarding stale decoder build (surface or connection changed)")
                        pipeline.release()
                    } else {
                        publishVideoPipeline(pipeline, request)
                    }
                    handedOver = true
                }
            } finally {
                // A destroyed Activity cancels this coroutine mid-handover; a
                // codec nobody ever published still has to be released.
                if (!handedOver) pipeline.release()
            }
        }
    }

    /** Everything the background build needs, read on the main thread. */
    private class VideoPipelineRequest(
        val surface: Surface,
        val surfaceIsValid: Boolean,
        val width: Int,
        val height: Int,
        val display: Display?,
        val mime: String,
        val useTextureView: Boolean,
        val gles31: Boolean,
        val vsrEnabled: Boolean,
        val vsrMode: String,
        val cflStrength: Float,
        val vsrSharpness: Float,
        val vsrEdgeThreshold: Float,
        val wirelessSession: Boolean,
    )

    private class VideoPipeline(
        val decoder: VideoDecoder,
        val sgsr: SgsrRenderer?,
        val cfl: CflRenderer?,
    ) {
        fun release() {
            decoder.release()
            sgsr?.release()
            cfl?.release()
        }
    }

    /** Background thread: renderer creation + decoder construction. */
    private fun buildVideoPipeline(request: VideoPipelineRequest): VideoPipeline {
        var sgsr: SgsrRenderer? = null
        var cfl: CflRenderer? = null
        var decoderSurface = request.surface
        val cflOn =
            request.vsrEnabled && request.vsrMode.equals("cfl", true) &&
                request.gles31 && !request.useTextureView
        val vsrOn = request.vsrEnabled && request.gles31 && !request.useTextureView && !cflOn

        if (cflOn) {
            // CfL chroma reconstruction via ByteBuffer-mode decode: the
            // decoder is configured WITHOUT a surface and hands
            // plane-accessible Images to the renderer (the ImageReader
            // route is dead on this SoC — opaque UBWC buffers whose
            // plane access is a fatal JNI abort).
            try {
                val renderer = CflRenderer()
                cfl = renderer
                renderer.onStats = { s ->
                    mainDiag("VSR stats: ${s.summary()}")
                    runOnUiThread { binding.streamStatusBarBinding.vsrText.text = s.summary() }
                }
                renderer.onUnavailable = { reason ->
                    mainDiag("CfL unavailable ($reason) — disabling, direct path")
                    runOnUiThread {
                        prefs.vsrEnabled = false
                        binding.streamStatusBarBinding.vsrText.text = getString(R.string.vsr_cfl_fallback)
                        restartVideoPath()
                    }
                }
                renderer.setStrength(request.cflStrength)
                renderer.initialize(request.surface, request.width, request.height)
                mainDiag("CfL active (luma-guided chroma reconstruction, buffer decode)")
            } catch (e: Exception) {
                mainDiag("CfL init failed (${e.message}) — falling back to direct surface")
                cfl?.release()
                cfl = null
                runOnUiThread { binding.streamStatusBarBinding.vsrText.text = getString(R.string.vsr_fallback) }
            }
        } else if (vsrOn) {
            try {
                val renderer = SgsrRenderer(applicationContext)
                sgsr = renderer
                renderer.onStats = { s ->
                    mainDiag(
                        "VSR stats: ${s.summary()} " +
                            "p95=${"%.1f".format(s.cpuP95Ms)}ms",
                    )
                    runOnUiThread { binding.streamStatusBarBinding.vsrText.text = s.summary() }
                }
                renderer.setMode(SgsrRenderer.Mode.from(request.vsrMode))
                renderer.setSharpness(request.vsrSharpness)
                renderer.setEdgeThreshold(request.vsrEdgeThreshold)
                renderer.initialize(request.surface, request.width, request.height)
                decoderSurface = renderer.decoderSurfaceRef ?: request.surface
                mainDiag("VSR active: mode=${request.vsrMode} sharpness=${request.vsrSharpness}")
            } catch (e: Exception) {
                mainDiag("VSR init failed (${e.message}) — falling back to direct surface")
                sgsr?.release()
                sgsr = null
                runOnUiThread { binding.streamStatusBarBinding.vsrText.text = getString(R.string.vsr_fallback) }
            }
        } else {
            runOnUiThread {
                binding.streamStatusBarBinding.vsrText.text =
                    if (request.vsrEnabled) getString(R.string.vsr_not_available) else getString(R.string.ui_off)
            }
        }

        val decoder =
            try {
                VideoDecoder(
                    decoderSurface,
                    request.display,
                    request.width,
                    request.height,
                    request.mime,
                    bufferOutput = cfl != null,
                    wireless = request.wirelessSession,
                    targetFrameRate =
                        if (request.wirelessSession) WirelessFreshnessPolicy.TARGET_FRAME_RATE else null,
                )
            } catch (e: Exception) {
                // The renderers are not published yet, so this is the only
                // reference that can release them.
                sgsr?.release()
                cfl?.release()
                throw e
            }
        return VideoPipeline(decoder, sgsr, cfl)
    }

    /** Main thread: wire callbacks and hand the pipeline to the frame path. */
    private fun publishVideoPipeline(
        pipeline: VideoPipeline,
        request: VideoPipelineRequest,
    ) {
        val decoder = pipeline.decoder
        videoDecoder = decoder
        sgsrRenderer = pipeline.sgsr
        cflRenderer = pipeline.cfl

        streamClient?.let { client -> bindDecoderCallbacks(client, activeConnectionGeneration) }
        pipeline.cfl?.let { renderer ->
            decoder.onDecodedImage = { img, done -> renderer.submitImage(img, done) }
            decoder.onColorRange = { range -> renderer.setFullRange(range == MediaFormat.COLOR_RANGE_FULL) }
            decoder.onImageOutputUnavailable = {
                runOnUiThread {
                    prefs.vsrEnabled = false
                    binding.streamStatusBarBinding.vsrText.text = getString(R.string.vsr_cfl_fallback)
                    restartVideoPath()
                }
            }
        }
        decoder.onDecodeLatency = { avgMs, maxMs ->
            mainDiag("decode latency avg=" + "%.1f".format(avgMs) + "ms max=" + "%.1f".format(maxMs) + "ms")
        }
        decoder.onDecodedFormat = { w, h, cl, cr, ct, cb ->
            mainDiag("decoder output format ${w}x$h crop=$cl,$cr,$ct,$cb")
            if (DisplayConfig.fromWire(w, h, 0) == null) {
                mainDiag("ignored unsafe decoder output size ${w}x$h")
            } else {
                // CfL self-sizes from each Image; SGSR needs the coded output size.
                sgsrRenderer?.resizeStream(w, h)
            }
        }
        decoder.onDecoderStalled = {
            // Black screen with live stats: tell the user why instead of
            // staying silent (issue #41). Toast renders above the (black)
            // SurfaceView; the settings panel is hidden while streaming.
            val cap = CodecCapabilities.maxDecodeSize(request.mime)
            runOnUiThread {
                val capText = cap?.let { " (max ~${it.first}×${it.second})" } ?: ""
                android.widget.Toast
                    .makeText(
                        this,
                        "No video output — the stream resolution may exceed " +
                            "this tablet's decoder limit$capText. " +
                            "Lower the resolution or disable HiDPI on the Mac.",
                        android.widget.Toast.LENGTH_LONG,
                    ).show()
            }
        }
        streamClient?.requestKeyframe(force = true, reason = "decoder initialized")
        mainDiag("Decoder initialized OK ${request.width}x${request.height} mime=${request.mime}, texture=${request.useTextureView}")
        log(
            "✅ Decoder initialized ${request.width}x${request.height} ${request.mime} " +
                "(${request.display?.refreshRate ?: 60f}Hz)",
        )
    }

    /**
     * Deliver frames from the socket thread without losing the first sync frame
     * to the UI-thread decoder startup race. The Mac stream can begin sending
     * immediately after display config; if the decoder is still being created,
     * release the bytes and ask for a throttled refresh so the next frame is an
     * IDR instead of leaving the decoder waiting on a P-frame forever.
     */
    private fun deliverFrame(
        client: StreamClient,
        generation: Long,
        frameData: ByteArray,
        frameSize: Int,
        timestamp: Long,
        isKeyframe: Boolean,
    ) {
        if (!isCurrentConnection(client, generation)) {
            client.releaseBuffer(frameData)
            return
        }

        val decoder = videoDecoder?.takeIf { it.isReady }
        if (decoder != null) {
            decoder.decode(frameData, frameSize, timestamp, isKeyframe)
            return
        }

        client.releaseBuffer(frameData)
        if (displayWidth > 0 && displayHeight > 0) {
            client.requestKeyframe(reason = "decoder not ready")
        }
        mainDiag("FRAME DROPPED: decoder not ready; requested refresh=$isKeyframe")
    }

    /** Wire all stream callbacks through the same client and generation fence. */
    private fun setupStreamClientCallbacks(
        client: StreamClient,
        generation: Long,
        host: String,
    ) {
        client.onFrameReceived = { frameData, frameSize, timestamp, isKeyframe ->
            deliverFrame(client, generation, frameData, frameSize, timestamp, isKeyframe)
        }

        bindDecoderCallbacks(client, generation)

        client.onLatencyMeasured = { rttMs ->
            if (isCurrentConnection(client, generation)) {
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) {
                        binding.streamStatusBarBinding.latencyText.text = getString(R.string.metric_latency_ms, rttMs)
                    }
                }
            }
        }

        // Real panel backlight from the host (BRIGHT over control channel).
        client.onBrightness = { v ->
            if (isCurrentConnection(client, generation)) applyBacklight(v)
        }

        client.onConnectionStatus = { connected ->
            runOnUiThread {
                if (!isCurrentConnection(client, generation)) {
                    if (connected) client.disconnect()
                    return@runOnUiThread
                }

                isConnected = connected
                macServerKnownAvailable = connected
                updateStatus(if (connected) "Connected - Streaming active" else "Disconnected")
                binding.connectButton.isEnabled = !connected
                binding.disconnectButton.isEnabled = connected
                binding.statusIndicator.setBackgroundResource(
                    if (connected) android.R.color.holo_green_light else android.R.color.holo_red_light,
                )
                if (connected) {
                    val isForeground =
                        lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
                    client.setLivenessPaused(!isForeground)
                    setDisplayKeepAwake(isForeground)
                    if (client.isWirelessSession) applyFrameRateHint()
                    if (isForeground) startPingTimer() else stopPingTimer()
                    stopChecklistUpdates()
                    enableFullscreenMode()
                    binding.settingsPanel.visibility = View.GONE
                    applySettingsButtonVisibility()
                    restoreSettingsButtonPosition()
                    updateOverlayVisibility(prefs.showStatsOverlay)
                    if (client.isWirelessSession) {
                        val entry = pairedHostStorage.load()
                        wirelessController.onConnectSuccess(
                            entry?.macName ?: "Mac",
                            client.connectedHost ?: entry?.host ?: host,
                        )
                    }
                } else {
                    setDisplayKeepAwake(false)
                    applyFrameRateHint()
                    streamClient = null
                    stopPingTimer()
                    releaseVideoPipeline()
                    displayWidth = 0
                    displayHeight = 0
                    displayFlipHorizontal = false
                    displayFlipVertical = false
                    displayConfigReceivedAtMs = 0L
                    applyDirectPixelMapping(0, 0)
                    disableFullscreenMode()
                    resetOrientationToSensor()
                    binding.settingsPanel.visibility = View.VISIBLE
                    binding.settingsButton.visibility = View.GONE
                    binding.streamStatusBarBinding.statusBar.visibility = View.GONE
                    if (client.isWirelessSession) {
                        // Wireless reconnection uses token-bound discovery and does
                        // not depend on the USB loopback checklist.
                        wirelessController.onStreamDisconnected()
                    } else {
                        startChecklistUpdates()
                        log("Connection lost — tap Connect to retry")
                    }
                }
            }
        }

        client.onCodecSelected = { isHevc ->
            if (isCurrentConnection(client, generation)) onStreamCodecSelected(isHevc)
        }

        client.onDisplaySize = { width, height, rotation, flipHorizontal, flipVertical ->
            if (isCurrentConnection(client, generation)) {
                mainDiag("onDisplaySize: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
                warnIfAvcOnlyWithoutNegotiation()
                displayWidth = width
                displayHeight = height
                displayRotation = rotation
                displayFlipHorizontal = flipHorizontal
                displayFlipVertical = flipVertical
                displayConfigReceivedAtMs = System.currentTimeMillis()
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) {
                        binding.streamStatusBarBinding.resolutionText.text = getString(R.string.stream_resolution, width, height)
                        applyFrameRateHint()
                        applyRotation(rotation, flipHorizontal, flipVertical)
                        applyDirectPixelMapping(width, height)
                        initializeDecoderForCurrentSurface()
                    }
                }
                log("Display: ${width}x$height @ $rotation°")
            }
        }

        client.onStats = { fps, mbps ->
            if (isCurrentConnection(client, generation)) {
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) {
                        binding.streamStatusBarBinding.fpsText.text = getString(R.string.metric_fps_value, fps)
                        binding.streamStatusBarBinding.bitrateText.text = getString(R.string.metric_bitrate_mbps, mbps)
                    }
                }
            }
        }
    }

    /** Bind a decoder to the exact client that supplied its pooled frame buffers. */
    private fun bindDecoderCallbacks(client: StreamClient, generation: Long) {
        videoDecoder?.onFrameDecoded = { buffer -> client.releaseBuffer(buffer) }
        videoDecoder?.onKeyframeRequired = { force, reason ->
            if (isCurrentConnection(client, generation)) {
                client.requestKeyframe(force = force, reason = reason)
            }
        }
    }

    private fun connectWireless(
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        controlPort: Int? = null,
        alternateHosts: List<String> = emptyList(),
    ) {
        val generation = activeConnectionGeneration + 1
        activeConnectionGeneration = generation
        streamClient?.disconnect()
        streamClient = null
        releaseVideoPipeline()
        isConnected = false
        displayWidth = 0
        displayHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        displayConfigReceivedAtMs = 0L

        val client =
            StreamClient(
                host,
                port,
                applicationContext,
                controlPort = controlPort ?: port + 1,
                alternateHosts = alternateHosts,
            )
        streamClient = client
        setupStreamClientCallbacks(client, generation, host)

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting wirelessly to $host:$port...")
                client.connectWireless(token, deviceName)
                // NOTE: onConnectSuccess is fired from the onConnectionStatus(true)
                // listener (above) right after handshake OK — not here. This line
                // would otherwise run AFTER the receive loop exits, i.e. AFTER
                // disconnect, incorrectly transitioning back to CONNECTED.
            } catch (e: StreamClient.WirelessConnectError) {
                if (!isCurrentConnection(client, generation)) return@launch
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) wirelessController.onConnectError(e)
                }
            } catch (e: Exception) {
                if (!isCurrentConnection(client, generation)) return@launch
                log("Wireless connect failed: ${e.message}")
                runOnUiThread {
                    if (isCurrentConnection(client, generation)) {
                        wirelessController.onConnectError(StreamClient.WirelessConnectError.NetworkUnreachable)
                    }
                }
            }
        }
    }

    private fun connect(
        host: String,
        port: Int,
    ) {
        // Invalidate and close the previous client before creating its
        // replacement. Older callbacks are fenced by this generation.
        val generation = activeConnectionGeneration + 1
        activeConnectionGeneration = generation
        streamClient?.disconnect()
        streamClient = null
        releaseVideoPipeline()
        isConnected = false
        displayWidth = 0
        displayHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        displayConfigReceivedAtMs = 0L

        // E3 carries bulk video through 10.77.0.1:54326. Keep tiny
        // latency/control packets on their dedicated adb-reverse port
        // so they cannot sit behind raw video frames in the E3 pipe.
        val usesE3VideoPath = host == LEGACY_E3_HOST && port == LEGACY_E3_PORT
        val client =
            StreamClient(
                host,
                port,
                applicationContext,
                controlHost = if (usesE3VideoPath) "127.0.0.1" else host,
                controlPort = if (usesE3VideoPath) 54322 else port + 1,
            )
        streamClient = client
        setupStreamClientCallbacks(client, generation, host)

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting to $host:$port...")
                client.connect()
            } catch (e: Exception) {
                if (activeConnectionGeneration != generation) return@launch
                val errorMessage =
                    when {
                        e is java.net.ConnectException -> {
                            "Mac server is not running.\n\nPlease start Side Screen.app on your Mac first."
                        }

                        e is java.net.NoRouteToHostException || e is java.net.UnknownHostException -> {
                            "Cannot reach Mac.\n\n" +
                                "Make sure both devices are connected via USB cable and ADB reverse is configured."
                        }

                        e is java.net.SocketTimeoutException -> {
                            "Connection timeout.\n\nCheck if Mac firewall is blocking port $port."
                        }

                        else -> {
                            "Connection failed: ${e.message}\n\n" +
                                "Try:\n• Start Side Screen.app on Mac\n" +
                                "• Check USB connection\n• Run: adb reverse tcp:$port tcp:$port"
                        }
                    }
                runOnUiThread {
                    if (activeConnectionGeneration != generation) return@runOnUiThread
                    updateStatus("Connection failed")
                    showError(errorMessage)
                }
            }
        }
    }

    private fun isCurrentConnection(
        client: StreamClient,
        generation: Long,
    ): Boolean = activeConnectionGeneration == generation && streamClient === client

    private fun disconnect(restoreUi: Boolean = true) {
        activeConnectionGeneration += 1
        stopPingTimer()
        streamClient?.disconnect()
        streamClient = null
        releaseVideoPipeline()
        isConnected = false
        setDisplayKeepAwake(false)
        applyFrameRateHint()
        // The server was reachable for this session; a user-initiated local
        // disconnect says nothing about its current availability.
        macServerKnownAvailable = null
        activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
        regularTouchActive = false
        // Reset display config so next connect defers decoder init until config arrives
        displayWidth = 0
        displayHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        displayConfigReceivedAtMs = 0L
        if (!restoreUi) {
            log("Disconnected")
            return
        }
        runOnUiThread {
            updateStatus("Disconnected")
            binding.connectButton.isEnabled = true
            binding.disconnectButton.isEnabled = false
            binding.statusIndicator.setBackgroundResource(R.drawable.status_indicator_neutral)
            disableFullscreenMode()
            resetOrientationToSensor()
            binding.settingsPanel.visibility = View.VISIBLE
            binding.settingsButton.visibility = View.GONE
            binding.streamStatusBarBinding.statusBar.visibility = View.GONE
            applyDirectPixelMapping(0, 0)
            binding.textureView.visibility = View.GONE
            applyTextureTransform()
            if (prefs.connectionMode == ConnectionMode.USB) {
                startChecklistUpdates()
            }
        }
        log("Disconnected")
    }

    private fun startPingTimer() {
        stopPingTimer()
        pingJob =
            lifecycleScope.launch(Dispatchers.IO) {
                while (true) {
                    kotlinx.coroutines.delay(1000) // Ping every 1 second
                    streamClient?.sendPing()
                }
            }
    }

    private fun stopPingTimer() {
        pingJob?.cancel()
        pingJob = null
    }

    private fun cleanup() {
        try {
            // The activity is going away: do not resurrect checklist polling or
            // touch views that are being torn down.
            disconnect(restoreUi = false)
            currentTextureSurface?.release()
            currentTextureSurface = null

            setDisplayKeepAwake(false)
            applyFrameRateHint()
        } catch (e: Exception) {
            log("⚠️ Cleanup error: ${e.message}")
        }
    }

    private fun handleTouch(
        view: View,
        event: MotionEvent,
    ) {
        val action = event.actionMasked
        val stylusIndex = findStylusPointerIndex(event)

        // A pen touching the display must start a direct mouse stroke. If a
        // finger gesture was already pending, close that gesture before
        // handing ownership to the pen so the Mac never sees two active input
        // modes at once.
        if ((action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_POINTER_DOWN) && stylusIndex >= 0) {
            if (regularTouchActive) {
                val touchIndex = findNonStylusPointerIndex(event)
                if (touchIndex >= 0) {
                    sendTouchSample(view, event, touchIndex, 2)
                }
                regularTouchActive = false
            }
            if (activeStylusPointerId == MotionEvent.INVALID_POINTER_ID) {
                activeStylusPointerId = event.getPointerId(stylusIndex)
                sendStylusSample(view, event, stylusIndex, StylusProtocol.ACTION_DOWN)
            }
            return
        }

        // Once the pen owns the sequence, ignore any companion finger
        // pointers. This keeps an S Pen stroke continuous when the heel of a
        // hand rests on the tablet.
        if (activeStylusPointerId != MotionEvent.INVALID_POINTER_ID) {
            val activeIndex = event.findPointerIndex(activeStylusPointerId)
            when {
                action == MotionEvent.ACTION_CANCEL -> {
                    if (activeIndex >= 0) {
                        sendStylusSample(view, event, activeIndex, StylusProtocol.ACTION_UP)
                    }
                    activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
                }

                activeIndex >= 0 &&
                    (action == MotionEvent.ACTION_MOVE ||
                        (action == MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.actionIndex) == activeStylusPointerId) ||
                        (action == MotionEvent.ACTION_UP && event.getPointerId(0) == activeStylusPointerId)) -> {
                    val stylusAction =
                        if (action == MotionEvent.ACTION_MOVE) StylusProtocol.ACTION_MOVE else StylusProtocol.ACTION_UP
                    sendStylusSample(view, event, activeIndex, stylusAction)
                    if (stylusAction == StylusProtocol.ACTION_UP) {
                        activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
                    }
                }
            }
            return
        }

        // If a device reports a stylus move without delivering its initial
        // ACTION_DOWN (seen after a surface recreation on some Samsung
        // firmware), recover the stroke instead of feeding it into touch
        // prediction.
        if (action == MotionEvent.ACTION_MOVE && stylusIndex >= 0) {
            activeStylusPointerId = event.getPointerId(stylusIndex)
            sendStylusSample(view, event, stylusIndex, StylusProtocol.ACTION_DOWN)
            return
        }

        // A SurfaceView reports width/height 0 before its first layout, and
        // 0/0 is NaN: coerceIn returns NaN unchanged, and the host's touch
        // parser has no finiteness guard. Normalise through the shared helper so
        // touch and stylus cannot disagree.
        if (!PointerCoordinates.isUsable(view.width, view.height)) {
            mainDiag("touch ignored — surface has no measured size (${view.width}x${view.height})")
            return
        }
        val x = PointerCoordinates.normalize(event.x, view.width, displayFlipHorizontal)
        val y = PointerCoordinates.normalize(event.y, view.height, displayFlipVertical)
        val pointerCount = event.pointerCount.coerceAtMost(2)

        var x2 = 0f
        var y2 = 0f
        if (pointerCount >= 2) {
            x2 = PointerCoordinates.normalize(event.getX(1), view.width, displayFlipHorizontal)
            y2 = PointerCoordinates.normalize(event.getY(1), view.height, displayFlipVertical)
        }

        when (action) {
            MotionEvent.ACTION_DOWN -> {
                regularTouchActive = true
                inputPredictor.reset()
                inputPredictor.addSample(x, y)
                streamClient?.sendTouch(x, y, 0, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                streamClient?.sendTouch(x, y, 0, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_MOVE -> {
                if (pointerCount == 1) {
                    inputPredictor.addSample(x, y)
                    val (px, py) = inputPredictor.predictPosition(12f)
                    streamClient?.sendTouch(px, py, 1, 1)
                } else {
                    streamClient?.sendTouch(x, y, 1, pointerCount, x2, y2)
                }
            }

            MotionEvent.ACTION_UP -> {
                regularTouchActive = false
                inputPredictor.reset()
                streamClient?.sendTouch(x, y, 2, 1)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                streamClient?.sendTouch(x, y, 2, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_CANCEL -> {
                regularTouchActive = false
                inputPredictor.reset()
                streamClient?.sendTouch(x, y, 2, 1)
            }
        }
    }

    private fun handleStylusHover(
        view: View,
        event: MotionEvent,
    ): Boolean {
        val action = event.actionMasked
        if (action != MotionEvent.ACTION_HOVER_ENTER &&
            action != MotionEvent.ACTION_HOVER_MOVE &&
            action != MotionEvent.ACTION_HOVER_EXIT
        ) {
            return false
        }
        val stylusIndex = findStylusPointerIndex(event)
        if (stylusIndex < 0) return false
        sendStylusSample(view, event, stylusIndex, StylusProtocol.ACTION_HOVER)
        return true
    }

    private fun findStylusPointerIndex(event: MotionEvent): Int {
        val active = activeStylusPointerId
        if (active != MotionEvent.INVALID_POINTER_ID) {
            val activeIndex = event.findPointerIndex(active)
            if (activeIndex >= 0 && isStylusTool(event.getToolType(activeIndex))) {
                return activeIndex
            }
        }
        for (index in 0 until event.pointerCount) {
            if (isStylusTool(event.getToolType(index))) return index
        }
        return -1
    }

    private fun findNonStylusPointerIndex(event: MotionEvent): Int {
        for (index in 0 until event.pointerCount) {
            if (!isStylusTool(event.getToolType(index))) return index
        }
        return -1
    }

    private fun isStylusTool(toolType: Int): Boolean =
        toolType == MotionEvent.TOOL_TYPE_STYLUS || toolType == MotionEvent.TOOL_TYPE_ERASER

    private fun sendTouchSample(
        view: View,
        event: MotionEvent,
        pointerIndex: Int,
        action: Int,
    ) {
        if (!PointerCoordinates.isUsable(view.width, view.height)) return
        if (pointerIndex !in 0 until event.pointerCount) return
        val x = PointerCoordinates.normalize(event.getX(pointerIndex), view.width)
        val y = PointerCoordinates.normalize(event.getY(pointerIndex), view.height)
        streamClient?.sendTouch(x, y, action, 1)
    }

    private fun sendStylusSample(
        view: View,
        event: MotionEvent,
        pointerIndex: Int,
        action: Int,
    ) {
        if (!PointerCoordinates.isUsable(view.width, view.height)) return
        if (pointerIndex !in 0 until event.pointerCount) return

        val x = PointerCoordinates.normalize(event.getX(pointerIndex), view.width, displayFlipHorizontal)
        val y = PointerCoordinates.normalize(event.getY(pointerIndex), view.height, displayFlipVertical)
        val pressure = if (action == StylusProtocol.ACTION_HOVER) 0f else event.getPressure(pointerIndex)
        val sample =
            StylusInputEvent(
                x = x,
                y = y,
                action = action,
                toolType = event.getToolType(pointerIndex),
                pressure = pressure,
                tilt = event.getAxisValue(MotionEvent.AXIS_TILT, pointerIndex),
                orientation = event.getAxisValue(MotionEvent.AXIS_ORIENTATION, pointerIndex),
                buttonState = event.buttonState,
            )

        val client = streamClient ?: return
        if (client.stylusSupported) {
            client.sendStylus(sample)
        } else if (action != StylusProtocol.ACTION_HOVER) {
            // Older hosts do not acknowledge the extension. Preserve basic
            // touch compatibility until the host is updated.
            client.sendTouch(x, y, action.coerceAtMost(2), 1)
        }
    }

    private fun applyRotation(
        rotation: Int,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
    ) {
        requestedOrientation =
            when (rotation) {
                90 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }

        binding.surfaceView.rotation = 0f
        binding.surfaceView.visibility = View.VISIBLE
        binding.textureView.visibility = if (flipHorizontal || flipVertical) View.VISIBLE else View.GONE
        applyTextureTransform()

        log(
            "🔄 Orientation: ${when (rotation) {
                90 -> "Portrait"
                180 -> "Landscape (flipped)"
                270 -> "Portrait (flipped)"
                else -> "Landscape"
            }}${if (flipHorizontal || flipVertical) " mirrored" else ""}",
        )
    }

    private fun applyTextureTransform() {
        val view = binding.textureView
        val matrix = Matrix()
        val centerX = view.width / 2f
        val centerY = view.height / 2f
        matrix.postScale(
            if (displayFlipHorizontal) -1f else 1f,
            if (displayFlipVertical) -1f else 1f,
            centerX,
            centerY,
        )
        view.setTransform(matrix)
    }

    /**
     * Reset orientation to follow device sensor (when disconnected)
     */
    private fun resetOrientationToSensor() {
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
    }

    // Local diagnostic text is intentionally not translated.
    @SuppressLint("SetTextI18n")
    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onStart() {
        super.onStart()
        setDisplayKeepAwake(isConnected && streamClient != null)
        mainDiag(
            "onStart connected=$isConnected display=${displayWidth}x$displayHeight " +
                "client=${streamClient != null}",
        )
        // Back in the foreground — cancel any pending auto-disconnect.
        backgroundedAtMs = 0L
        autoDisconnectJob?.cancel()
        autoDisconnectJob = null
        if (isConnected) {
            // Samsung firmware can defer background socket delivery. Do not
            // queue pings while stopped; resume fresh RTT samples only after
            // the activity and decoder surface are visible again.
            streamClient?.setLivenessPaused(false)
            startPingTimer()
            // Some Android builds recreate the SurfaceView without delivering a
            // second display-config packet. Rebind the decoder to the new
            // surface using the last negotiated stream dimensions.
            binding.surfaceView.post {
                if (isConnected) initializeDecoderForCurrentSurface()
            }
        }
    }

    override fun onStop() {
        super.onStop()
        // Android may turn the screen off after this Activity leaves the foreground.
        setDisplayKeepAwake(false)
        mainDiag(
            "onStop connected=$isConnected display=${displayWidth}x$displayHeight " +
                "client=${streamClient != null}",
        )
        // Do not queue pings while the activity is backgrounded. If Android
        // delays delivery, those pongs would otherwise be measured as
        // multi-second latency after the next foreground transition.
        streamClient?.setLivenessPaused(true)
        stopPingTimer()
        // Backgrounded while streaming: arm the auto-disconnect timer.
        if (!isConnected) return
        backgroundedAtMs = System.currentTimeMillis()
        val secs =
            Settings.System.getInt(contentResolver, "sidescreen_auto_disconnect_secs", 300)
                .coerceAtLeast(10)
        autoDisconnectJob =
            lifecycleScope.launch {
                delay(secs * 1000L)
                if (
                    isConnected &&
                    backgroundedAtMs > 0 &&
                    System.currentTimeMillis() - backgroundedAtMs >= secs * 1000L
                ) {
                    DiagLog.log("MA", "auto-disconnect: backgrounded > ${secs}s — tearing down session")
                    disconnect()
                }
            }
    }

    override fun onDestroy() {
        vsrCmdReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // The activity context already removed the receiver.
            }
            vsrCmdReceiver = null
        }
        wirelessController.close()
        super.onDestroy()
        stopChecklistUpdates()
        cleanup()
    }

    // ==================== Connection Checklist ====================

    private fun startChecklistUpdates() {
        // Stop any existing runnable first to prevent duplicates. This loop
        // updates device-local prerequisites only; it never opens a network
        // socket. The Mac status is learned only from an explicit Connect.
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
        }

        checklistRunnable =
            object : Runnable {
                override fun run() {
                    updateChecklist()
                    checklistHandler.postDelayed(this, 2000) // Update local state every 2 seconds
                }
            }
        checklistHandler.post(checklistRunnable!!)
    }

    private fun stopChecklistUpdates() {
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
            checklistRunnable = null
        }
    }

    private fun updateChecklist() {
        // Skip while connected or while an explicit connection attempt is in
        // flight. There are no automatic network probes here: a Mac status is
        // known only after the user has pressed Connect/Reconnect.
        if (isConnected || streamClient != null) return

        // Check Developer Mode (if we can run this app with USB debugging, dev mode is enabled)
        val isDeveloperModeEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkDeveloperMode, isDeveloperModeEnabled)

        // Check USB Debugging (ADB enabled)
        val isAdbEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.ADB_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkUsbDebugging, isAdbEnabled)

        // In device/peripheral mode Android does not expose the Mac as a
        // UsbManager device. Read the protected sticky USB-state broadcast so
        // a data-only ADB cable is not reported as disconnected just because
        // the tablet is not charging and has no USB host peripherals.
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val usbState =
            runCatching {
                registerReceiver(null, IntentFilter("android.hardware.usb.action.USB_STATE"))
            }.getOrNull()
        val isUsbConnected =
            usbState?.getBooleanExtra("connected", false) == true ||
                usbState?.getBooleanExtra("configured", false) == true ||
                usbManager.deviceList.isNotEmpty() ||
                isCharging()
        updateChecklistItem(binding.checkUsbConnected, isUsbConnected)

        // Do not probe the Mac here. A short health-check socket is still an
        // unsolicited connection and can be mistaken for a reconnect by the
        // host or by a user watching its logs.
        updateChecklistItem(binding.checkMacServer, macServerKnownAvailable)
        binding.textMacServer.text =
            getString(
                when (macServerKnownAvailable) {
                    true -> R.string.ui_mac_server_running
                    false -> R.string.ui_mac_server_not_responding
                    null -> R.string.ui_mac_server_not_checked
                },
            )

        val localPrerequisitesReady = isDeveloperModeEnabled && isAdbEnabled && isUsbConnected
        updateMainStatus(
            ConnectionReadinessPolicy.evaluate(localPrerequisitesReady, macServerKnownAvailable),
        )
    }

    private fun updateMainStatus(state: ConnectionReadinessState) {
        val (indicator, statusText) =
            when (state) {
                ConnectionReadinessState.LOCAL_SETUP_REQUIRED ->
                    R.drawable.status_indicator_red to R.string.ui_not_ready_to_connect
                ConnectionReadinessState.SERVER_UNCHECKED ->
                    R.drawable.status_indicator_neutral to R.string.ui_tap_connect_to_check_server
                ConnectionReadinessState.SERVER_UNAVAILABLE ->
                    R.drawable.status_indicator_red to R.string.ui_mac_server_not_responding
                ConnectionReadinessState.READY ->
                    R.drawable.status_indicator_green to R.string.ui_ready_to_connect
            }
        binding.statusIndicator.setBackgroundResource(indicator)
        binding.statusText.setText(statusText)
    }

    private fun updateChecklistItem(
        indicator: View,
        isOk: Boolean?,
    ) {
        indicator.setBackgroundResource(
            when (isOk) {
                true -> R.drawable.status_indicator_green
                false -> R.drawable.status_indicator_red
                null -> R.drawable.status_indicator_neutral
            },
        )
    }

    private fun isCharging(): Boolean {
        val intentFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus = registerReceiver(null, intentFilter)
        val status = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        return status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
    }

    private companion object {
        const val DIRECT_PIXEL_MIN_SCALE = 0.97f
    }

    /**
     * Apply a host-issued brightness (0..255) to the REAL panel backlight.
     * Settings.System.SCREEN_BRIGHTNESS requires WRITE_SETTINGS (appop,
     * granted via: adb shell appops set com.sidescreen.app WRITE_SETTINGS allow).
     * We force manual mode once per apply so the panel honors the value
     * (auto-brightness would otherwise override it). Runs on the control
     * thread — the writes are quick binder calls; no UI hop needed.
     */
    private fun applyBacklight(value: Int) {
        val v = value.coerceIn(0, 255)
        try {
            Settings.System.putInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
            )
            Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, v)
            DiagLog.log("BRT", "backlight applied value=$v")
        } catch (e: Exception) {
            DiagLog.log("BRT", "backlight failed: ${e.message}")
        }
    }
}
