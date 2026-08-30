package com.sidescreen.app

/**
 * The encoded stream size belongs to the decoder, not to the Android window.
 * Keeping a SurfaceView at the negotiated pixel dimensions creates a centered
 * border on tablets whose panel aspect/size differs from the Mac capture.
 *
 * ConstraintLayout width/height of 0 means "match the four parent constraints".
 * The platform then scales the decoder output into the visible panel.
 */
internal data class SurfaceLayoutDecision(
    val width: Int,
    val height: Int,
    val geometryKnown: Boolean,
)

internal object SurfaceLayoutPolicy {
    fun decide(
        streamWidth: Int,
        streamHeight: Int,
        panelWidth: Int,
        panelHeight: Int,
    ): SurfaceLayoutDecision =
        SurfaceLayoutDecision(
            width = 0,
            height = 0,
            geometryKnown =
                streamWidth > 0 &&
                    streamHeight > 0 &&
                    panelWidth > 0 &&
                    panelHeight > 0,
        )
}
