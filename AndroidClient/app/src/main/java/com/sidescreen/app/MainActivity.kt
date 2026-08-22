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

private fun mainDiag(msg: String) = DiagLog.log("MA", msg)

// Debug A/B hook action: adb shell am broadcast -a com.sidescreen.app.VSR_CMD
//   --ez enabled true --es mode sgsr [--ef sharpness 0.8] [--ef edge_threshold 0.03]
//   --ez enabled true --es mode cfl [--ef cfl_strength 0.15] [--ez color_profile false]
private const val VSR_CMD_ACTION = "com.sidescreen.app.VSR_CMD"
private const val DEFAULT_USB_HOST = "127.0.0.1"
private const val DEFAULT_USB_PORT = 54321
private const val LEGACY_E3_HOST = "10.77.0.1"
private const val LEGACY_E3_PORT = 54326

class MainActivity : AppCompatActivity() {
    private lateinit var wirelessController: WirelessTabController
    private val pairedHostStorage by lazy { PairedHostStorage(this) }
    private val cameraPerm by lazy { CameraPermissionManager(this) }
    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: PreferencesManager
    private var videoDecoder: VideoDecoder? = null
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

    private var manualConnectionState = ManualConnectionState.READY

    private enum class ManualConnectionState {
        READY,
        CONNECTING,
        CONNECTED,
        PAUSED,
        FAILED,
    }

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // Input prediction for low-latency gaming
    private val inputPredictor = InputPredictor()

    // Checklist status handler
    private val checklistHandler = Handler(Looper.getMainLooper())
    private var checklistRunnable: Runnable? = null
    private var isConnected = false // Track connection state to prevent checklist conflicts

    // Auto-disconnect: if the app stays backgrounded past the configured
    // window (default 60 s; adb-tunable via
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

        // USB screen sharing is deliberately manual. ADB/USB becoming
        // available must never open a video or control socket on its own.
        log("Manual connection mode enabled — tap Connect to start")
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
            if (mode == ConnectionMode.WIRELESS) {
                wirelessController.show()
            }
        }
    }

    private fun applyModeVisibility(mode: ConnectionMode) {
        binding.usbModeContent.visibility = if (mode == ConnectionMode.USB) View.VISIBLE else View.GONE
        binding.wirelessModeContent.visibility = if (mode == ConnectionMode.WIRELESS) View.VISIBLE else View.GONE
        // Checklist updates are local-only while idle. They must not probe the
        // Mac listener because the host accepts one screen-sharing client and
        // a background probe can look like an unwanted reconnect.
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
                onConnectRequested = { host, port, token, deviceName, macName ->
                    connectWireless(host, port, token, deviceName, macName)
                },
            )
        wirelessController.bind()
        binding.wirelessDisconnectButton.setOnClickListener { disconnect() }
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

    /** Keep the panel awake only while an active stream is visible. */
    private fun updateScreenPowerState(streamingVisible: Boolean) {
        if (streamingVisible) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
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
                    mainDiag("surfaceChanged: ${width}x$height")
                    log("Surface changed: ${width}x$height")
                    currentSurfaceHolder = holder
                    initializeDecoderForCurrentSurface()
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mainDiag("surfaceDestroyed")
                    log("Surface destroyed")
                    if (!decoderUsingTextureView) {
                        videoDecoder?.release()
                        videoDecoder = null
                        sgsrRenderer?.release()
                        sgsrRenderer = null
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
                        videoDecoder?.release()
                        videoDecoder = null
                        sgsrRenderer?.release()
                        sgsrRenderer = null
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
    }

    private fun setupUI() {
        binding.connectButton.setOnClickListener {
            var host =
                binding.hostInput.text
                    .toString()
                    .ifEmpty { DEFAULT_USB_HOST }
            val port =
                binding.portInput.text
                    .toString()
                    .toIntOrNull() ?: DEFAULT_USB_PORT

            // Convert localhost to 127.0.0.1 for better Android compatibility
            if (host.equals("localhost", ignoreCase = true)) {
                host = "127.0.0.1"
            }

            // Validate input
            if (host.isBlank()) {
                showError("Please enter a host address")
                return@setOnClickListener
            }

            if (manualConnectionState == ManualConnectionState.CONNECTING) {
                return@setOnClickListener
            }

            manualConnectionState = ManualConnectionState.CONNECTING
            binding.connectButton.isEnabled = false
            setStatusIndicator(R.drawable.status_indicator_amber)
            updateStatus("Connecting…")
            connect(host, port)
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
        updateStatus("Ready — tap Connect to start")
        setStatusIndicator(R.drawable.status_indicator_amber)
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

    private fun setStatusIndicator(drawableRes: Int) {
        binding.statusIndicator.setBackgroundResource(drawableRes)
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    private fun setupDraggableOverlay() {
        binding.statusBar.setOnTouchListener { view, event ->
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
            binding.statusBar.post {
                binding.statusBar.x = x
                binding.statusBar.y = y
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
        binding.statusBar.alpha = opacity
    }

    private fun updateOverlayVisibility(show: Boolean) {
        if (streamClient != null && show) {
            binding.statusBar.visibility = View.VISIBLE
            // Restore position when showing
            val x = prefs.overlayX
            val y = prefs.overlayY
            if (x >= 0 && y >= 0) {
                binding.statusBar.post {
                    binding.statusBar.x = x
                    binding.statusBar.y = y
                }
            }
        } else {
            binding.statusBar.visibility = View.GONE
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

        val androidColorProfileSwitch = view.findViewById<SwitchMaterial>(R.id.androidColorProfileSwitch)
        val androidColorProfileStatus = view.findViewById<TextView>(R.id.androidColorProfileStatus)
        val colorProfileSupported = supportsGles31()
        androidColorProfileSwitch.isChecked = prefs.androidColorProfileEnabled
        androidColorProfileSwitch.isEnabled = colorProfileSupported
        androidColorProfileStatus.text =
            if (colorProfileSupported) AndroidColorProfile.NAME else "Requires OpenGL ES 3.1 GPU path"
        androidColorProfileSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.androidColorProfileEnabled = isChecked
            val needsUsbDirectPathRebuild =
                isConnected &&
                    prefs.connectionMode == ConnectionMode.USB &&
                    !prefs.vsrEnabled &&
                    supportsGles31() &&
                    !shouldUseTextureView()
            if (needsUsbDirectPathRebuild) {
                // The direct MediaCodec -> Surface path has no shader stage.
                // Rebuild only that local path so the profile can be added or
                // removed without disconnecting USB or restarting the stream.
                restartVideoPath()
            } else {
                sgsrRenderer?.setAndroidColorProfileEnabled(isChecked)
                cflRenderer?.setAndroidColorProfileEnabled(isChecked)
            }
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
            binding.statusBar
                .animate()
                .x(dm.widthPixels - binding.statusBar.width - 48f)
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
        val constraintLayout = binding.root as ConstraintLayout
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
     * Display config from a new Mac always arrives AFTER codecSelected, so a
     * missing negotiation at this point proves the Mac app predates H.264
     * support — surface that instead of a silent black screen.
     */
    private fun warnIfAvcOnlyWithoutNegotiation() {
        if (!CodecCapabilities.hasHevcDecoder && streamClient?.codecNegotiated != true) {
            mainDiag("AVC-only device but Mac did not negotiate codec — Mac app too old")
            runOnUiThread {
                updateStatus("This device has no HEVC decoder. Update the SideScreen Mac app to enable H.264 support.")
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

    private fun isUsbColorBridgePathActive(): Boolean =
        prefs.connectionMode == ConnectionMode.USB &&
            prefs.androidColorProfileEnabled &&
            supportsGles31() &&
            !shouldUseTextureView() &&
            !prefs.vsrEnabled

    /** Recreate the video path (decoder + optional VSR renderer) with current prefs. */
    private fun restartVideoPath() {
        if (!isConnected) return
        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
        applyDirectPixelMapping(displayWidth, displayHeight)
        initializeDecoderForCurrentSurface()
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
            val usbColorBridgeOn = isUsbColorBridgePathActive()
            val nearNative =
                !usbColorBridgeOn &&
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
                "Surface mapping: ${if (usbColorBridgeOn) "GPU upscale/fill" else if (nearNative) "1:1" else "fill"} " +
                    "stream=${streamWidth}x$streamHeight panel=${panelWidth}x$panelHeight",
            )
        }
    }

    private var vsrCmdReceiver: BroadcastReceiver? = null

    /** Debug A/B hook: adb broadcast to switch VSR modes headlessly (no UI taps, no reconnect). */
    private fun setupVsrCommandReceiver() {
        if (vsrCmdReceiver != null) return
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    context: Context?,
                    intent: Intent?,
                ) {
                    val i = intent ?: return
                    if (i.action != VSR_CMD_ACTION) return
                    val mode = i.getStringExtra("mode")
                    val directUsbProfilePath =
                        isConnected &&
                            prefs.connectionMode == ConnectionMode.USB &&
                            !prefs.vsrEnabled &&
                            supportsGles31() &&
                            !shouldUseTextureView()
                    val profileChangesVideoPath = i.hasExtra("color_profile") && directUsbProfilePath
                    val changesVideoPath =
                        mode != null ||
                            i.hasExtra("enabled") ||
                            i.hasExtra("sharpness") ||
                            i.hasExtra("cfl_strength") ||
                            i.hasExtra("edge_threshold") ||
                            profileChangesVideoPath
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
                    if (changesVideoPath) prefs.vsrEnabled = enabled
                    if (i.hasExtra("color_profile")) {
                        val profileEnabled = i.getBooleanExtra("color_profile", AndroidColorProfile.DEFAULT_ENABLED)
                        prefs.androidColorProfileEnabled = profileEnabled
                        if (!profileChangesVideoPath) {
                            sgsrRenderer?.setAndroidColorProfileEnabled(profileEnabled)
                            cflRenderer?.setAndroidColorProfileEnabled(profileEnabled)
                        }
                    }
                    mainDiag(
                        "VSR_CMD: enabled=${if (changesVideoPath) enabled else prefs.vsrEnabled} " +
                            "mode=${prefs.vsrMode} colorProfile=${prefs.androidColorProfileEnabled}",
                    )
                    if (changesVideoPath) restartVideoPath()
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

    private fun initializeDecoderForCurrentSurface() {
        if (displayWidth <= 0 || displayHeight <= 0) {
            mainDiag("initializeDecoder skipped — no display config yet")
            return
        }
        // AVC-only device: an HEVC decoder can never decode the H.264 stream
        // the Mac will send — defer until codecSelected arrives, then
        // onStreamCodecSelected initializes with the correct mime.
        if (!CodecCapabilities.hasHevcDecoder && streamClient?.codecNegotiated != true) {
            mainDiag("initializeDecoder deferred — AVC-only device awaiting codec negotiation")
            return
        }

        val (surface, useTextureView) =
            activeVideoSurface() ?: run {
                val kind = if (shouldUseTextureView()) "TextureView" else "SurfaceView"
                mainDiag("initializeDecoder skipped — no valid $kind surface")
                return
            }

        if (videoDecoder != null && decoderUsingTextureView == useTextureView && sgsrRenderer == null && cflRenderer == null) {
            videoDecoder?.updateResolution(displayWidth, displayHeight)
            return
        }

        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
        decoderUsingTextureView = useTextureView

        mainDiag(
            "initializeDecoder called, surface=$surface, valid=${surface.isValid}, " +
                "res=${displayWidth}x$displayHeight, texture=$useTextureView",
        )
        try {
            val displayObj =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    display
                } else {
                    @Suppress("DEPRECATION")
                    windowManager.defaultDisplay
                }
            val mime =
                if (streamClient?.streamCodecIsHevc == false) {
                    MediaFormat.MIMETYPE_VIDEO_AVC
                } else {
                    MediaFormat.MIMETYPE_VIDEO_HEVC
                }
            var decoderSurface = surface
            val cflOn = prefs.vsrEnabled && prefs.vsrMode.equals("cfl", true) &&
                supportsGles31() && !useTextureView
            val vsrOn = prefs.vsrEnabled && supportsGles31() && !useTextureView && !cflOn
            val usbColorBridgeOn = isUsbColorBridgePathActive() && !cflOn && !vsrOn
            if (cflOn) {
                // CfL chroma reconstruction via ByteBuffer-mode decode: the
                // decoder is configured WITHOUT a surface and hands
                // plane-accessible Images to the renderer (the ImageReader
                // route is dead on this SoC — opaque UBWC buffers whose
                // plane access is a fatal JNI abort).
                try {
                    val renderer = CflRenderer()
                    renderer.initialize(surface, displayWidth, displayHeight)
                    renderer.onStats = { s ->
                        mainDiag("VSR stats: ${s.summary()}")
                        runOnUiThread { binding.vsrText.text = s.summary() }
                    }
                    val unavailable: (String) -> Unit = { reason ->
                        mainDiag("CfL unavailable ($reason) — disabling, direct path")
                        runOnUiThread {
                            prefs.vsrEnabled = false
                            binding.vsrText.text = "cfl fallback"
                            restartVideoPath()
                        }
                    }
                    renderer.onPlanesUnavailable = unavailable
                    renderer.setStrength(prefs.cflStrength)
                    renderer.setAndroidColorProfileEnabled(prefs.androidColorProfileEnabled)
                    cflRenderer = renderer
                    mainDiag(
                        "CfL active (luma-guided chroma reconstruction, buffer decode) " +
                            "colorProfile=${prefs.androidColorProfileEnabled}",
                    )
                } catch (e: Exception) {
                    mainDiag("CfL init failed (${e.message}) — falling back to direct surface")
                    cflRenderer?.release()
                    cflRenderer = null
                    runOnUiThread { binding.vsrText.text = "fallback" }
                }
            } else if (vsrOn || usbColorBridgeOn) {
                try {
                    val renderer = SgsrRenderer(
                        applicationContext,
                        frameRateCap = if (usbColorBridgeOn) {
                            AndroidColorProfile.USB_BRIDGE_FPS_CAP
                        } else {
                            null
                        },
                    )
                    renderer.initialize(surface, displayWidth, displayHeight)
                    renderer.setMode(
                        if (usbColorBridgeOn) {
                            SgsrRenderer.Mode.BRIDGE_ONLY
                        } else {
                            SgsrRenderer.Mode.from(prefs.vsrMode)
                        },
                    )
                    renderer.setSharpness(prefs.vsrSharpness)
                    renderer.setEdgeThreshold(prefs.vsrEdgeThreshold)
                    renderer.setAndroidColorProfileEnabled(prefs.androidColorProfileEnabled)
                    renderer.onStats = { s ->
                        mainDiag(
                            "VSR stats: ${s.summary()} " +
                                "p95=${"%.1f".format(s.cpuP95Ms)}ms",
                        )
                        runOnUiThread { binding.vsrText.text = s.summary() }
                    }
                    sgsrRenderer = renderer
                    decoderSurface = renderer.decoderSurfaceRef ?: surface
                    if (usbColorBridgeOn) {
                        mainDiag(
                            "USB color bridge active: sRGB / BT.709 profile=" +
                                "${prefs.androidColorProfileEnabled} " +
                                "fpsCap=${AndroidColorProfile.USB_BRIDGE_FPS_CAP}",
                        )
                    } else {
                        mainDiag(
                            "VSR active: mode=${prefs.vsrMode} sharpness=${prefs.vsrSharpness} " +
                                "colorProfile=${prefs.androidColorProfileEnabled}",
                        )
                    }
                } catch (e: Exception) {
                    mainDiag("VSR init failed (${e.message}) — falling back to direct surface")
                    sgsrRenderer?.release()
                    sgsrRenderer = null
                    runOnUiThread { binding.vsrText.text = "fallback" }
                }
            } else {
                runOnUiThread {
                    binding.vsrText.text =
                        if (prefs.vsrEnabled) "n/a" else "off"
                }
            }
            val useBufferOutput = cflRenderer != null
            videoDecoder = VideoDecoder(
                decoderSurface,
                displayObj,
                displayWidth,
                displayHeight,
                mime,
                targetFrameRate = when {
                    prefs.connectionMode == ConnectionMode.WIRELESS ->
                        WirelessTransportProfile.TARGET_FPS
                    usbColorBridgeOn -> AndroidColorProfile.USB_BRIDGE_FPS_CAP
                    else -> null
                },
                bufferOutput = useBufferOutput,
            )
            videoDecoder?.onColorRange = { range ->
                val fullRange = range != 2
                sgsrRenderer?.setFullRange(fullRange)
                cflRenderer?.setFullRange(fullRange)
            }
            if (useBufferOutput) {
                cflRenderer?.let { renderer ->
                    videoDecoder?.onDecodedImage = { img, done -> renderer.submitImage(img, done) }
                    videoDecoder?.onImageOutputUnavailable = {
                        runOnUiThread {
                            prefs.vsrEnabled = false
                            binding.vsrText.text = "cfl fallback"
                            restartVideoPath()
                        }
                    }
                }
            }
            videoDecoder?.onDecodeLatency = { avgMs, maxMs ->
                mainDiag("decode latency avg=" + "%.1f".format(avgMs) + "ms max=" + "%.1f".format(maxMs) + "ms")
            }
            videoDecoder?.onDecodedFormat = { w, h, cl, cr, ct, cb ->
                mainDiag("decoder output format ${w}x$h crop=$cl,$cr,$ct,$cb")
                // CfL renderer self-sizes its textures from the first Image.
                sgsrRenderer?.resizeStream(w, h, cl, cr, ct, cb)
            }
            videoDecoder?.onFrameDecoded = { buffer ->
                streamClient?.releaseBuffer(buffer)
            }
            videoDecoder?.onKeyframeRequired = { force, reason ->
                streamClient?.requestKeyframe(force = force, reason = reason)
            }
            videoDecoder?.onDecoderStalled = {
                // Black screen with live stats: tell the user why instead of
                // staying silent (issue #41). Toast renders above the (black)
                // SurfaceView; the settings panel is hidden while streaming.
                val cap = CodecCapabilities.maxDecodeSize(mime)
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
            mainDiag("Decoder initialized OK ${displayWidth}x$displayHeight mime=$mime, texture=$useTextureView")
            val effectiveDecoderRate = when {
                prefs.connectionMode == ConnectionMode.WIRELESS ->
                    WirelessTransportProfile.TARGET_FPS.toFloat()
                usbColorBridgeOn -> AndroidColorProfile.USB_BRIDGE_FPS_CAP.toFloat()
                else -> displayObj?.refreshRate ?: 60f
            }
            log("✅ Decoder initialized ${displayWidth}x$displayHeight $mime (${effectiveDecoderRate}Hz target)")
        } catch (e: Exception) {
            decoderUsingTextureView = false
            mainDiag("Decoder init FAILED: ${e.message}")
            log("❌ Failed to initialize decoder: ${e.message}")
            runOnUiThread {
                updateStatus("Video decoder failed: ${e.message}")
            }
        }
    }

    /**
     * Wire up all StreamClient callbacks. Used by both USB connect() and wireless connectWireless().
     */
    private fun setupStreamClientCallbacks() {
        streamClient?.onFrameReceived = { frameData, frameSize, timestamp, isKeyframe ->
            val dec = videoDecoder
            if (dec != null) {
                dec.decode(frameData, frameSize, timestamp, isKeyframe)
            } else {
                mainDiag("FRAME DROPPED: videoDecoder is null!")
            }
        }

        videoDecoder?.onFrameDecoded = { buffer ->
            streamClient?.releaseBuffer(buffer)
        }

        streamClient?.onLatencyMeasured = { rttMs ->
            runOnUiThread {
                binding.latencyText.text = String.format("%.1f ms", rttMs)
            }
        }

        // Real panel backlight from the host (BRIGHT over control channel).
        streamClient?.onBrightness = { v -> applyBacklight(v) }

        streamClient?.onConnectionStatus = { connected ->
            runOnUiThread {
                isConnected = connected
                manualConnectionState =
                    if (connected) ManualConnectionState.CONNECTED else ManualConnectionState.PAUSED
                if (connected) {
                    updateStatus("Connected · streaming active")
                } else {
                    updateStatus("Connection paused · tap Connect to resume")
                }
                binding.connectButton.isEnabled = !connected
                binding.disconnectButton.isEnabled = connected
                setStatusIndicator(
                    if (connected) R.drawable.status_indicator_green else R.drawable.status_indicator_amber,
                )
                if (connected) {
                    updateScreenPowerState(true)
                    startPingTimer()
                    stopChecklistUpdates()
                    enableFullscreenMode()
                    binding.settingsPanel.visibility = View.GONE
                    applySettingsButtonVisibility()
                    restoreSettingsButtonPosition()
                    updateOverlayVisibility(prefs.showStatsOverlay)
                    // For wireless mode, transition controller to CONNECTED here —
                    // not in MainActivity.connectWireless's coroutine after the
                    // receive loop returns (that runs AFTER disconnect, causing
                    // a stale CONNECTED transition that hides the PAIRED_IDLE UI).
                    if (prefs.connectionMode == ConnectionMode.WIRELESS) {
                        val entry = pairedHostStorage.load()
                        wirelessController.onConnectSuccess(
                            entry?.macName ?: "Mac",
                            entry?.host ?: "—",
                        )
                    }
                } else {
                    updateScreenPowerState(false)
                    releaseVideoPipeline()
                    stopPingTimer()
                    disableFullscreenMode()
                    resetOrientationToSensor()
                    binding.settingsPanel.visibility = View.VISIBLE
                    binding.settingsButton.visibility = View.GONE
                    binding.statusBar.visibility = View.GONE
                    val mode = prefs.connectionMode
                    val willTransition = mode == ConnectionMode.WIRELESS
                    android.util.Log.i(
                        "MainActivity",
                        "onConnectionStatus(false) — mode=$mode, willTransition=$willTransition",
                    )
                    if (mode == ConnectionMode.WIRELESS) {
                        // Don't restart checklist (it conflicts with wireless on Mac).
                        // Tell wireless controller to show the idle/reconnect UI.
                        wirelessController.onStreamDisconnected()
                    } else {
                        log("Manual reconnect required — automatic reconnect is disabled")
                        startChecklistUpdates()
                    }
                }
            }
        }

        streamClient?.onCodecSelected = { isHevc -> onStreamCodecSelected(isHevc) }

        streamClient?.onDisplaySize = { width, height, rotation, flipHorizontal, flipVertical ->
            mainDiag("onDisplaySize: ${width}x$height @ $rotation°, h=$flipHorizontal, v=$flipVertical")
            warnIfAvcOnlyWithoutNegotiation()
            displayWidth = width
            displayHeight = height
            displayRotation = rotation
            displayFlipHorizontal = flipHorizontal
            displayFlipVertical = flipVertical
            runOnUiThread {
                binding.resolutionText.text = "${width}x$height"
                applyRotation(rotation, flipHorizontal, flipVertical)
                applyDirectPixelMapping(width, height)
                initializeDecoderForCurrentSurface()
            }
            log("Display: ${width}x$height @ $rotation°")
        }

        streamClient?.onStats = { fps, mbps ->
            runOnUiThread {
                binding.fpsText.text = String.format("%.1f", fps)
                binding.bitrateText.text = String.format("%.1f Mbps", mbps)
            }
        }
    }

    private fun connectWireless(
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        macName: String,
    ) {
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting wirelessly to $host:$port...")
                streamClient = StreamClient(host, port, applicationContext)
                setupStreamClientCallbacks()
                streamClient?.connectWireless(token, deviceName)
                // NOTE: onConnectSuccess is fired from the onConnectionStatus(true)
                // listener (above) right after handshake OK — not here. This line
                // would otherwise run AFTER the receive loop exits, i.e. AFTER
                // disconnect, incorrectly transitioning back to CONNECTED.
            } catch (e: StreamClient.WirelessConnectError) {
                runOnUiThread {
                    wirelessController.onConnectError(e)
                }
            } catch (e: Exception) {
                log("Wireless connect failed: ${e.message}")
                runOnUiThread {
                    wirelessController.onConnectError(StreamClient.WirelessConnectError.NetworkUnreachable)
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
        isConnected = false

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

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting to $host:$port...")

                client.onFrameReceived = { frameData, frameSize, timestamp, isKeyframe ->
                    if (isCurrentConnection(client, generation)) {
                        val dec = videoDecoder
                        if (dec != null) {
                            dec.decode(frameData, frameSize, timestamp, isKeyframe)
                        } else {
                            client.releaseBuffer(frameData)
                        }
                    } else {
                        client.releaseBuffer(frameData)
                    }
                }

                // Wire up buffer release callback for buffer pooling
                // When decode completes, buffer is returned to StreamClient's pool
                videoDecoder?.onFrameDecoded = { buffer -> client.releaseBuffer(buffer) }
                videoDecoder?.onKeyframeRequired = { force, reason ->
                    if (isCurrentConnection(client, generation)) {
                        client.requestKeyframe(force = force, reason = reason)
                    }
                }

                // Latency measurement via ping/pong
                client.onLatencyMeasured = { rttMs ->
                    if (isCurrentConnection(client, generation)) {
                        runOnUiThread {
                            if (isCurrentConnection(client, generation)) {
                                binding.latencyText.text = String.format("%.1f ms", rttMs)
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
                            // A stale client must never flip the UI to
                            // disconnected or schedule another reconnect.
                            if (connected) client.disconnect()
                            return@runOnUiThread
                        }

                        // Update connection state flag
                        isConnected = connected
                        manualConnectionState =
                            if (connected) ManualConnectionState.CONNECTED else ManualConnectionState.PAUSED

                        if (connected) {
                            updateStatus("Connected · streaming active")
                        } else {
                            updateStatus("Connection paused · tap Connect to resume")
                        }

                        binding.connectButton.isEnabled = !connected
                        binding.disconnectButton.isEnabled = connected

                        // Update status indicator color
                        setStatusIndicator(
                            if (connected) {
                                R.drawable.status_indicator_green
                            } else {
                                R.drawable.status_indicator_amber
                            },
                        )

                        if (connected) {
                            updateScreenPowerState(true)
                            // Start periodic ping for latency measurement
                            startPingTimer()

                            // Stop local-only checklist updates while the stream is active.
                            stopChecklistUpdates()

                            // Enter fullscreen mode when connected
                            enableFullscreenMode()

                            binding.settingsPanel.visibility = View.GONE
                            applySettingsButtonVisibility()
                            restoreSettingsButtonPosition()
                            updateOverlayVisibility(prefs.showStatsOverlay)
                        } else {
                            updateScreenPowerState(false)
                            releaseVideoPipeline()
                            // Stop ping timer
                            stopPingTimer()

                            // Exit fullscreen mode when disconnected
                            disableFullscreenMode()

                            // Reset to follow device sensor when disconnected
                            resetOrientationToSensor()

                            binding.settingsPanel.visibility = View.VISIBLE
                            binding.settingsButton.visibility = View.GONE
                            binding.statusBar.visibility = View.GONE

                            // Resume local-only checklist updates. Reconnecting is
                            // intentionally left to the user.
                            log("Manual reconnect required — automatic reconnect is disabled")
                            startChecklistUpdates()
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

                        runOnUiThread {
                            if (isCurrentConnection(client, generation)) {
                                binding.resolutionText.text = "${width}x$height"
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
                                binding.fpsText.text = String.format("%.1f", fps)
                                binding.bitrateText.text = String.format("%.1f Mbps", mbps)
                            }
                        }
                    }
                }

                client.connect()
            } catch (e: Exception) {
                if (!isCurrentConnection(client, generation)) return@launch
                val errorMessage =
                    when {
                        e.message?.contains("ECONNREFUSED") == true -> {
                            "Mac server is not running.\n\nPlease start Side Screen.app on your Mac first."
                        }

                        e.message?.contains("Network is unreachable") == true -> {
                            "Cannot reach Mac.\n\n" +
                                "Make sure both devices are connected via USB cable and ADB reverse is configured."
                        }

                        e.message?.contains("timeout") == true -> {
                            "Connection timeout.\n\nCheck if Mac firewall is blocking port $port."
                        }

                        else -> {
                            "Connection failed: ${e.message}\n\n" +
                                "Try:\n• Start Side Screen.app on Mac\n" +
                                "• Check USB connection\n• Run: adb reverse tcp:$port tcp:$port"
                        }
                    }
                runOnUiThread {
                    if (!isCurrentConnection(client, generation)) return@runOnUiThread
                    manualConnectionState = ManualConnectionState.FAILED
                    binding.connectButton.isEnabled = true
                    binding.disconnectButton.isEnabled = false
                    setStatusIndicator(R.drawable.status_indicator_red)
                    updateStatus("Connection failed · tap Connect to retry")
                    showError(errorMessage)
                }
            }
        }
    }

    private fun isCurrentConnection(
        client: StreamClient,
        generation: Long,
    ): Boolean = activeConnectionGeneration == generation && streamClient === client

    private fun disconnect(restartChecklist: Boolean = true) {
        activeConnectionGeneration += 1
        manualConnectionState = ManualConnectionState.READY
        isConnected = false
        stopPingTimer()
        streamClient?.disconnect()
        streamClient = null
        releaseVideoPipeline()
        // Reset display config so next connect defers decoder init until config arrives
        displayWidth = 0
        displayHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        runOnUiThread {
            updateScreenPowerState(false)
            disableFullscreenMode()
            resetOrientationToSensor()
            applyDirectPixelMapping(0, 0)
            binding.textureView.visibility = View.GONE
            applyTextureTransform()
            binding.settingsPanel.visibility = View.VISIBLE
            binding.settingsButton.visibility = View.GONE
            binding.statusBar.visibility = View.GONE
            binding.connectButton.isEnabled = true
            binding.disconnectButton.isEnabled = false
            setStatusIndicator(R.drawable.status_indicator_amber)
            updateStatus("Ready — tap Connect to start")
            if (restartChecklist && prefs.connectionMode == ConnectionMode.USB) {
                startChecklistUpdates()
            }
        }
        log("Disconnected — automatic reconnect is disabled")
    }

    private fun releaseVideoPipeline() {
        videoDecoder?.release()
        videoDecoder = null
        sgsrRenderer?.release()
        sgsrRenderer = null
        cflRenderer?.release()
        cflRenderer = null
    }

    private fun startPingTimer() {
        stopPingTimer()
        pingJob =
            lifecycleScope.launch(Dispatchers.IO) {
                while (true) {
                    kotlinx.coroutines.delay(LATENCY_PING_INTERVAL_MS)
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
            disconnect(restartChecklist = false)
            currentTextureSurface?.release()
            currentTextureSurface = null
        } catch (e: Exception) {
            log("⚠️ Cleanup error: ${e.message}")
        }
    }

    private fun handleTouch(
        view: View,
        event: MotionEvent,
    ) {
        val rawX = event.x / view.width.toFloat()
        val rawY = event.y / view.height.toFloat()
        val x = if (displayFlipHorizontal) 1f - rawX else rawX
        val y = if (displayFlipVertical) 1f - rawY else rawY
        val pointerCount = event.pointerCount.coerceAtMost(2)

        var x2 = 0f
        var y2 = 0f
        if (pointerCount >= 2) {
            val rawX2 = event.getX(1) / view.width.toFloat()
            val rawY2 = event.getY(1) / view.height.toFloat()
            x2 = if (displayFlipHorizontal) 1f - rawX2 else rawX2
            y2 = if (displayFlipVertical) 1f - rawY2 else rawY2
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
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
                inputPredictor.reset()
                streamClient?.sendTouch(x, y, 2, 1)
            }

            MotionEvent.ACTION_POINTER_UP -> {
                streamClient?.sendTouch(x, y, 2, pointerCount, x2, y2)
            }

            MotionEvent.ACTION_CANCEL -> {
                inputPredictor.reset()
                streamClient?.sendTouch(x, y, 2, 1)
            }
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

    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onStart() {
        super.onStart()
        // Back in the foreground — cancel any pending auto-disconnect.
        backgroundedAtMs = 0L
        autoDisconnectJob?.cancel()
        autoDisconnectJob = null
        updateScreenPowerState(isConnected)
        if (isConnected) {
            startPingTimer()
        }
        if (!isConnected && prefs.connectionMode == ConnectionMode.USB) {
            startChecklistUpdates()
        }
    }

    override fun onStop() {
        super.onStop()
        updateScreenPowerState(false)
        stopPingTimer()
        // Backgrounded while streaming: arm the auto-disconnect timer.
        if (!isConnected) return
        backgroundedAtMs = System.currentTimeMillis()
        val secs =
            Settings.System.getInt(contentResolver, "sidescreen_auto_disconnect_secs", DEFAULT_BACKGROUND_DISCONNECT_SECS)
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
                    disconnect(restartChecklist = false)
                }
            }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopChecklistUpdates()
        cleanup()
    }

    // ==================== Connection Checklist ====================

    private fun startChecklistUpdates() {
        // Stop any existing runnable first to prevent duplicates
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
        }

        checklistRunnable =
            object : Runnable {
                override fun run() {
                    updateChecklist()
                    checklistHandler.postDelayed(this, CHECKLIST_INTERVAL_MS) // Local checks only; no host polling
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
        // Skip if connected (to prevent socket conflicts)
        if (isConnected) return

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

        // Check USB connected (check if any USB device is connected)
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val isUsbConnected = usbManager.deviceList.isNotEmpty() || isCharging()
        updateChecklistItem(binding.checkUsbConnected, isUsbConnected)

        // The Mac server is intentionally not probed while idle. A TCP probe
        // is still a screen-sharing connection from the host's perspective,
        // and can contend with the real client. The first explicit Connect
        // is the only server check.
        binding.textMacServer.text = "Mac server · checked when you tap Connect"
        updateChecklistPending(binding.checkMacServer)

        val localSetupReady = isDeveloperModeEnabled && isAdbEnabled && isUsbConnected
        updateMainStatus(localSetupReady)
    }

    private fun updateMainStatus(localSetupReady: Boolean) {
        when (manualConnectionState) {
            ManualConnectionState.READY -> {
                setStatusIndicator(
                    if (localSetupReady) {
                        R.drawable.status_indicator_amber
                    } else {
                        R.drawable.status_indicator_red
                    },
                )
                binding.statusText.text =
                    if (localSetupReady) {
                        "Ready — tap Connect to start"
                    } else {
                        "USB setup needs attention"
                    }
            }

            ManualConnectionState.CONNECTING -> {
                setStatusIndicator(R.drawable.status_indicator_amber)
                binding.statusText.text = "Connecting…"
            }

            ManualConnectionState.PAUSED -> {
                setStatusIndicator(R.drawable.status_indicator_amber)
                binding.statusText.text = "Connection paused · tap Connect to resume"
            }

            ManualConnectionState.FAILED -> {
                setStatusIndicator(R.drawable.status_indicator_red)
                binding.statusText.text = "Connection failed · tap Connect to retry"
            }

            ManualConnectionState.CONNECTED -> Unit
        }
    }

    private fun updateChecklistItem(
        indicator: View,
        isOk: Boolean,
    ) {
        indicator.setBackgroundResource(
            if (isOk) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
    }

    private fun updateChecklistPending(indicator: View) {
        indicator.setBackgroundResource(R.drawable.status_indicator_pending)
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
        const val DEFAULT_BACKGROUND_DISCONNECT_SECS = 60
        const val LATENCY_PING_INTERVAL_MS = 2_000L
        const val CHECKLIST_INTERVAL_MS = 10_000L
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
