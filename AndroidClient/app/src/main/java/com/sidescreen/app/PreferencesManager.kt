package com.sidescreen.app

import android.content.Context
import android.content.SharedPreferences
import kotlin.math.roundToInt

internal fun snapToStep(
    raw: Float,
    valueFrom: Float,
    valueTo: Float,
    stepSize: Float,
): Float {
    val safe = if (raw.isFinite()) raw else valueFrom
    val clamped = safe.coerceIn(valueFrom, valueTo)
    val steps = ((clamped - valueFrom) / stepSize).roundToInt()
    return (valueFrom + steps * stepSize).coerceIn(valueFrom, valueTo)
}

class PreferencesManager(
    context: Context,
) {
    private val prefs: SharedPreferences = context.getSharedPreferences("app_prefs", Context.MODE_PRIVATE)

    var showStatsOverlay: Boolean
        get() = prefs.getBoolean("show_stats", true)
        set(value) = prefs.edit().putBoolean("show_stats", value).apply()

    var overlayOpacity: Float
        get() = snapToStep(prefs.getFloat("overlay_opacity", 0.8f), 0.2f, 1.0f, 0.05f)
        set(value) = prefs.edit().putFloat("overlay_opacity", snapToStep(value, 0.2f, 1.0f, 0.05f)).apply()

    var overlayX: Float
        get() = prefs.getFloat("overlay_x", -1f)
        set(value) = prefs.edit().putFloat("overlay_x", value).apply()

    var overlayY: Float
        get() = prefs.getFloat("overlay_y", -1f)
        set(value) = prefs.edit().putFloat("overlay_y", value).apply()

    var settingsButtonX: Float
        get() = prefs.getFloat("settings_x", -1f)
        set(value) = prefs.edit().putFloat("settings_x", value).apply()

    var settingsButtonY: Float
        get() = prefs.getFloat("settings_y", -1f)
        set(value) = prefs.edit().putFloat("settings_y", value).apply()

    // Corner position: 0=bottom-right, 1=bottom-left, 2=top-right, 3=top-left
    var settingsButtonCorner: Int
        get() = prefs.getInt("settings_corner", 0)
        set(value) = prefs.edit().putInt("settings_corner", value).apply()

    var hideSettingsButton: Boolean
        get() = prefs.getBoolean("hide_settings_button", false)
        set(value) = prefs.edit().putBoolean("hide_settings_button", value).apply()

    var connectionMode: ConnectionMode
        get() = ConnectionMode.fromName(prefs.getString("connection_mode", null))
        set(value) = prefs.edit().putString("connection_mode", value.name).apply()

    // Video Super Resolution (receiver-side GPU postprocess)
    var vsrEnabled: Boolean
        get() = prefs.getBoolean("vsr_enabled", false)
        set(value) = prefs.edit().putBoolean("vsr_enabled", value).apply()

    var vsrMode: String
        get() = prefs.getString("vsr_mode", "sgsr") ?: "sgsr"
        set(value) = prefs.edit().putString("vsr_mode", value).apply()

    var vsrSharpness: Float
        get() = snapToStep(prefs.getFloat("vsr_sharpness", 0.8f), 0.0f, 1.0f, 0.05f)
        set(value) = prefs.edit().putFloat("vsr_sharpness", snapToStep(value, 0.0f, 1.0f, 0.05f)).apply()

    /** CfL chroma reconstruction strength. Kept separate from CAS/SGSR
     * sharpness because strong luma-derived chroma detail can look glossy. */
    var cflStrength: Float
        get() = prefs.getFloat("cfl_strength", 0.15f).coerceIn(0f, 1f)
        set(value) = prefs.edit().putFloat("cfl_strength", value.coerceIn(0f, 1f)).apply()

    var vsrEdgeThreshold: Float
        get() = snapToStep(prefs.getFloat("vsr_edge_threshold", 0.03f), 0.0f, 0.1f, 0.005f)
        set(value) = prefs.edit().putFloat("vsr_edge_threshold", snapToStep(value, 0.0f, 0.1f, 0.005f)).apply()
}
