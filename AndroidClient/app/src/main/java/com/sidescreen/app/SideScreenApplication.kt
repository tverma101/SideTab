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
 * lower variable-refresh-rate mode. On Android 14+ tell the scheduler the true
 * 120-FPS intent directly. On older Android releases, where preferredRefreshRate
 * must be an advertised rate, pick the closest same-resolution panel mode.
 *
 * This remains a preference, not a forced mode switch; thermal, power, user and
 * vendor policy may override it. We request it once at MainActivity startup
 * rather than tracking the host's adaptive 60/90/120 ladder, because frequent
 * refresh transitions can themselves drop frames.
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
