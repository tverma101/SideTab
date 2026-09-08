package com.sidescreen.app

import android.app.Activity
import android.app.Application
import android.os.Build
import android.os.Bundle
import android.view.Display

/**
 * Window-level display policy for the interactive remote-desktop surface.
 *
 * SideScreen can deliver up to 120 FPS, but Android may start the activity on a
 * lower variable-refresh-rate mode. Ask WindowManager for the highest refresh
 * rate at or below 120 Hz that is actually advertised at the panel's current
 * physical resolution. This is a preference, not a forced mode switch, and the
 * OS may ignore it for thermal/power/user-policy reasons.
 *
 * We set the preference once when MainActivity is created rather than tracking
 * the host's adaptive 60/90/120 ladder. Android explicitly discourages frequent
 * frame-rate requests because the display transition itself can drop frames.
 */
class SideScreenApplication : Application(), Application.ActivityLifecycleCallbacks {
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
            DisplayRefreshPolicy.choosePreferredRate(
                sameResolutionRates = sameResolutionRates,
                currentRate = current.refreshRate,
            )

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
            "Interactive display policy: current=${"%.2f".format(current.refreshRate)}Hz " +
                "preferred=${"%.2f".format(preferred)}Hz " +
                "sameRes=${sameResolutionRates.joinToString(prefix = "[", postfix = "]") { "%.2f".format(it) }}",
        )
    }

    @Suppress("DEPRECATION")
    private fun activityDisplay(activity: Activity): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            activity.windowManager.defaultDisplay
        }

    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
