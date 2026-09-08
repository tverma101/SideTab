package com.sidescreen.app

import android.app.Activity
import android.app.Application
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import java.util.WeakHashMap

/**
 * Display policy for the interactive remote-desktop surface.
 *
 * SideScreen can deliver up to 120 FPS, but Android may start the activity on a
 * lower variable-refresh-rate mode. The window preference remains the fallback
 * for old Android releases and the TextureView/mirrored path. On Android 11+
 * the direct SurfaceView additionally calls Surface.setFrameRate(120), which is
 * Android's preferred per-surface API and lets the compositor choose a panel
 * mode compatible with the app's actual 120-FPS intent.
 *
 * This remains a preference, not a forced mode switch; thermal, power, user and
 * vendor policy may override it. We install the hint once per surface lifetime
 * rather than tracking the host's adaptive 60/90/120 ladder, because frequent
 * refresh transitions can themselves drop frames.
 */
class SideScreenApplication : Application(), Application.ActivityLifecycleCallbacks {
    private val surfaceCallbacks = WeakHashMap<Activity, SurfaceHolder.Callback>()

    override fun onCreate() {
        super.onCreate()
        DiagLog.init(this)
        registerActivityLifecycleCallbacks(this)
    }

    override fun onActivityCreated(
        activity: Activity,
        savedInstanceState: Bundle?,
    ) {
        if (activity is MainActivity) {
            applyInteractiveDisplayPolicy(activity)
        }
    }

    private fun applyInteractiveDisplayPolicy(activity: Activity) {
        val display = activityDisplay(activity) ?: return
        val current = display.mode
        val sameResolutionRates =
            display.supportedModes
                .asSequence()
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                        it.physicalHeight == current.physicalHeight
                }
                .map { it.refreshRate }
                .distinct()
                .sorted()
                .toList()

        val preferred =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                DisplayRefreshPolicy.modernPreferredRate()
            } else {
                DisplayRefreshPolicy.chooseLegacyPreferredRate(
                    sameResolutionRates = sameResolutionRates,
                    currentRate = current.refreshRate,
                )
            }

        val attrs = activity.window.attributes
        attrs.preferredRefreshRate = preferred
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android documents this specifically for latency-sensitive games
            // and video conferencing. Internal-panel behavior is device-defined
            // and the user/system is still free to ignore the request.
            attrs.preferMinimalPostProcessing = true
        }
        activity.window.attributes = attrs

        DiagLog.log(
            "DISPLAY",
            "Interactive display policy: api=${Build.VERSION.SDK_INT} " +
                "current=${"%.2f".format(current.refreshRate)}Hz " +
                "preferred=${"%.2f".format(preferred)}Hz " +
                "sameRes=${sameResolutionRates.joinToString(prefix = "[", postfix = "]") { "%.2f".format(it) }}",
        )
    }

    /**
     * Surface.setFrameRate is preferred to a window-only hint on Android 11+.
     * SideScreen content is interactive/variable rather than fixed-cadence film,
     * so DEFAULT compatibility allows Android to pick the best refresh mode.
     */
    private fun installSurfaceFrameRatePolicy(activity: MainActivity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || surfaceCallbacks.containsKey(activity)) return
        val surfaceView = activity.findViewById<SurfaceView>(R.id.surfaceView) ?: return
        val holder = surfaceView.holder

        fun apply(surface: Surface) {
            if (!surface.isValid) return
            try {
                surface.setFrameRate(
                    DisplayRefreshPolicy.STREAM_INTENT_HZ,
                    Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                )
                DiagLog.log(
                    "DISPLAY",
                    "Surface frame-rate intent=${DisplayRefreshPolicy.STREAM_INTENT_HZ}Hz applied",
                )
            } catch (e: Exception) {
                // A vendor compositor may reject or ignore a frame-rate hint.
                // Streaming must continue with the window/system-selected mode.
                DiagLog.log("DISPLAY", "Surface frame-rate hint rejected: ${e.message}")
            }
        }

        val callback =
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    apply(holder.surface)
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    apply(holder.surface)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
            }

        holder.addCallback(callback)
        surfaceCallbacks[activity] = callback
        apply(holder.surface)
    }

    @Suppress("DEPRECATION")
    private fun activityDisplay(activity: Activity): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            activity.windowManager.defaultDisplay
        }

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityResumed(activity: Activity) {
        if (activity is MainActivity) {
            installSurfaceFrameRatePolicy(activity)
        }
    }

    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) {
        val callback = surfaceCallbacks.remove(activity) ?: return
        val surfaceView = activity.findViewById<SurfaceView>(R.id.surfaceView) ?: return
        surfaceView.holder.removeCallback(callback)
    }
}
