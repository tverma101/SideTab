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
import android.os.PowerManager
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
import java.nio.ByteBuffer
import java.nio.ByteOrder

private fun mainDiag(msg: String) = DiagLog.log("MA", msg)

// Debug A/B hook action: adb shell am broadcast -a com.sidescreen.app.VSR_CMD
//   --ez enabled true --es mode sgsr [--ef sharpness 0.8] [--ef edge_threshold 0.03]
//   --ez enabled true --es mode cfl [--ef cfl_strength 0.15]
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
    private var wakeLock: PowerManager.WakeLock? = null
    private var pingJob: kotlinx.coroutines.Job? = null

    // All callbacks from an old StreamClient become inert as soon as a newer
    // connect starts. Without this generation fence, a sender restart can
    // leave several clients reconnecting at once and starve the decoder.
    @Volatile private var activeConnectionGeneration = 0L

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
    private var macServerKnownAvailable = false

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

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Enable edge-to-edge display (draw behind system bars and cutout)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Apply fullscreen mode immediately
        enableFullscreenMode()

        // Enable performance mode for gaming (after binding is initialized)
        enablePerformanceMode()

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
            if (mode == ConnectionMode.WIRELESS) {
                wirelessController.show()
            }
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
                onConnectRequested = { host, port, token, deviceName, _ ->
                    connectWireless(host, port, token, deviceName)
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

    /**
     * Enable performance mode for streaming
     * NOTE: setSustainedPerformanceMode is DISABLED - it causes thermal throttling
     * which makes the entire device laggy. Normal power management is more efficient.
     */
    private fun enablePerformanceMode() {
        try {
            // REMOVED: setSustainedPerformanceMode(true)
            // Sustained performance mode forces max CPU/GPU clocks which causes
            // thermal throttling on extended use, making the device laggy.
            // Let the SoC manage power efficiently instead.

            // Use PARTIAL_WAKE_LOCK with timeout to prevent battery drain
            // Screen is already kept on via FLAG_KEEP_SCREEN_ON
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock =
                powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SideScreen::PerformanceMode",
                )
            // 30 minute timeout instead of infinite acquire
            wakeLock?.acquire(30 * 60 * 1000L)

            log("🎮 Performance mode ENABLED (balanced)")
        } catch (e: Exception) {
            log("⚠️ Performance mode failed: ${e.message}")
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
                    mainDiag(
                        "surfaceChanged: ${width}x$height connected=$isConnected " +
                            "display=${displayWidth}x$displayHeight client=${streamClient != null}",
                    )
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
        binding.surfaceView.setOnHoverListener { view, event ->
            handleStylusHover(view, event)
        }
        binding.textureView.setOnHoverListener { view, event ->
            handleStylusHover(view, event)
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

            updateStatus("Connecting...")
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
                    cflRenderer = renderer
                    mainDiag("CfL active (luma-guided chroma reconstruction, buffer decode)")
                } catch (e: Exception) {
                    mainDiag("CfL init failed (${e.message}) — falling back to direct surface")
                    cflRenderer?.release()
                    cflRenderer = null
                    runOnUiThread { binding.vsrText.text = "fallback" }
                }
            } else if (vsrOn) {
                try {
                    val renderer = SgsrRenderer(applicationContext)
                    renderer.initialize(surface, displayWidth, displayHeight)
                    renderer.setMode(SgsrRenderer.Mode.from(prefs.vsrMode))
                    renderer.setSharpness(prefs.vsrSharpness)
                    renderer.setEdgeThreshold(prefs.vsrEdgeThreshold)
                    renderer.onStats = { s ->
                        mainDiag(
                            "VSR stats: ${s.summary()} " +
                                "p95=${"%.1f".format(s.cpuP95Ms)}ms",
                        )
                        runOnUiThread { binding.vsrText.text = s.summary() }
                    }
                    sgsrRenderer = renderer
                    decoderSurface = renderer.decoderSurfaceRef ?: surface
                    mainDiag("VSR active: mode=${prefs.vsrMode} sharpness=${prefs.vsrSharpness}")
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
            videoDecoder = VideoDecoder(decoderSurface, displayObj, displayWidth, displayHeight, mime, bufferOutput = useBufferOutput)
            if (useBufferOutput) {
                cflRenderer?.let { renderer ->
                    videoDecoder?.onDecodedImage = { img, done -> renderer.submitImage(img, done) }
                    videoDecoder?.onColorRange = { range -> renderer.setFullRange(range != 2) }
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
            log("✅ Decoder initialized ${displayWidth}x$displayHeight $mime (${displayObj?.refreshRate ?: 60f}Hz)")
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
     * Wire up the wireless client's callbacks with the same generation fence
     * used by the USB path. A wireless connect can be cancelled while its
     * handshake socket is still local to the IO coroutine, so every callback
     * must remain tied to this exact client instance.
     */
    private fun setupStreamClientCallbacks(
        client: StreamClient,
        generation: Long,
        host: String,
    ) {
        client.onFrameReceived = { frameData, frameSize, timestamp, isKeyframe ->
            if (isCurrentConnection(client, generation)) {
                val dec = videoDecoder
                if (dec != null) {
                    dec.decode(frameData, frameSize, timestamp, isKeyframe)
                } else {
                    client.releaseBuffer(frameData)
                    mainDiag("FRAME DROPPED: videoDecoder is null!")
                }
            } else {
                client.releaseBuffer(frameData)
            }
        }

        videoDecoder?.onFrameDecoded = { buffer ->
            client.releaseBuffer(buffer)
        }
        videoDecoder?.onKeyframeRequired = { force, reason ->
            if (isCurrentConnection(client, generation)) {
                client.requestKeyframe(force = force, reason = reason)
            }
        }

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
                    startPingTimer()
                    stopChecklistUpdates()
                    enableFullscreenMode()
                    binding.settingsPanel.visibility = View.GONE
                    applySettingsButtonVisibility()
                    restoreSettingsButtonPosition()
                    updateOverlayVisibility(prefs.showStatsOverlay)
                    val entry = pairedHostStorage.load()
                    wirelessController.onConnectSuccess(
                        entry?.macName ?: "Mac",
                        entry?.host ?: host,
                    )
                } else {
                    streamClient = null
                    stopPingTimer()
                    disableFullscreenMode()
                    resetOrientationToSensor()
                    binding.settingsPanel.visibility = View.VISIBLE
                    binding.settingsButton.visibility = View.GONE
                    binding.statusBar.visibility = View.GONE
                    // Do not restart the USB checklist: its loopback probes can
                    // contend with a wireless session on the Mac.
                    wirelessController.onStreamDisconnected()
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
    }

    private fun connectWireless(
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
    ) {
        val generation = activeConnectionGeneration + 1
        activeConnectionGeneration = generation
        streamClient?.disconnect()
        streamClient = null
        isConnected = false

        val client = StreamClient(host, port, applicationContext)
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
                            // disconnected or alter the active session.
                            if (connected) client.disconnect()
                            return@runOnUiThread
                        }

                        // Update connection state flag
                        isConnected = connected
                        macServerKnownAvailable = connected

                        if (connected) {
                            updateStatus("Connected - Streaming active")
                        } else {
                            updateStatus("Disconnected")
                        }

                        binding.connectButton.isEnabled = !connected
                        binding.disconnectButton.isEnabled = connected

                        // Update status indicator color
                        binding.statusIndicator.setBackgroundResource(
                            if (connected) {
                                android.R.color.holo_green_light
                            } else {
                                android.R.color.holo_red_light
                            },
                        )

                        if (connected) {
                            // Start periodic ping for latency measurement
                            startPingTimer()

                            // Stop checklist updates when connected (prevents socket conflicts)
                            stopChecklistUpdates()

                            // Enter fullscreen mode when connected
                            enableFullscreenMode()

                            binding.settingsPanel.visibility = View.GONE
                            applySettingsButtonVisibility()
                            restoreSettingsButtonPosition()
                            updateOverlayVisibility(prefs.showStatsOverlay)
                        } else {
                            streamClient = null
                            // Stop ping timer
                            stopPingTimer()

                            // Exit fullscreen mode when disconnected
                            disableFullscreenMode()

                            // Reset to follow device sensor when disconnected
                            resetOrientationToSensor()

                            binding.settingsPanel.visibility = View.VISIBLE
                            binding.settingsButton.visibility = View.GONE
                            binding.statusBar.visibility = View.GONE

                            // Restart checklist updates immediately
                            log("📋 Restarting checklist updates")
                            startChecklistUpdates()

                            // A dropped session stays disconnected until the
                            // user presses Connect again.
                            log("Connection lost — tap Connect to retry")
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

    private fun disconnect() {
        activeConnectionGeneration += 1
        stopPingTimer()
        streamClient?.disconnect()
        streamClient = null
        isConnected = false
        macServerKnownAvailable = false
        activeStylusPointerId = MotionEvent.INVALID_POINTER_ID
        regularTouchActive = false
        // Reset display config so next connect defers decoder init until config arrives
        displayWidth = 0
        displayHeight = 0
        displayFlipHorizontal = false
        displayFlipVertical = false
        runOnUiThread {
            updateStatus("Disconnected")
            binding.connectButton.isEnabled = true
            binding.disconnectButton.isEnabled = false
            binding.statusIndicator.setBackgroundResource(android.R.color.holo_red_light)
            disableFullscreenMode()
            resetOrientationToSensor()
            binding.settingsPanel.visibility = View.VISIBLE
            binding.settingsButton.visibility = View.GONE
            binding.statusBar.visibility = View.GONE
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
            disconnect()
            videoDecoder?.release()
            videoDecoder = null
            sgsrRenderer?.release()
            sgsrRenderer = null
            cflRenderer?.release()
            cflRenderer = null
            currentTextureSurface?.release()
            currentTextureSurface = null

            // Release wake lock safely
            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
            } catch (e: Exception) {
                // Ignore wake lock release errors
            }
            wakeLock = null
            log("🎮 Performance mode DISABLED")
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
        if (view.width <= 0 || view.height <= 0) return
        val x = (event.getX(pointerIndex) / view.width.toFloat()).coerceIn(0f, 1f)
        val y = (event.getY(pointerIndex) / view.height.toFloat()).coerceIn(0f, 1f)
        streamClient?.sendTouch(x, y, action, 1)
    }

    private fun sendStylusSample(
        view: View,
        event: MotionEvent,
        pointerIndex: Int,
        action: Int,
    ) {
        if (view.width <= 0 || view.height <= 0 || pointerIndex !in 0 until event.pointerCount) return

        val rawX = (event.getX(pointerIndex) / view.width.toFloat()).coerceIn(0f, 1f)
        val rawY = (event.getY(pointerIndex) / view.height.toFloat()).coerceIn(0f, 1f)
        val x = if (displayFlipHorizontal) 1f - rawX else rawX
        val y = if (displayFlipVertical) 1f - rawY else rawY
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

    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onStart() {
        super.onStart()
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
        mainDiag(
            "onStop connected=$isConnected display=${displayWidth}x$displayHeight " +
                "client=${streamClient != null}",
        )
        // Do not queue pings while the activity is backgrounded. If Android
        // delays delivery, those pongs would otherwise be measured as
        // multi-second latency after the next foreground transition.
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

        // Update main status indicator based on local prerequisites plus the
        // last explicit connection result.
        val allReady = isDeveloperModeEnabled && isAdbEnabled && isUsbConnected && macServerKnownAvailable
        updateMainStatus(allReady)
    }

    private fun updateMainStatus(allReady: Boolean) {
        binding.statusIndicator.setBackgroundResource(
            if (allReady) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
        binding.statusText.text = if (allReady) "Ready to connect" else "Not ready to connect"
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
