package com.sidescreen.app

/**
 * Receiver-side color profile for the Tab S8+ SDR display path.
 *
 * The stream is already rendered by macOS before it reaches Android. This
 * profile cannot make arbitrary macOS glyphs become Android glyphs, but it
 * can compensate for the repeatable 4:2:0 chroma bias measured on the
 * 2800x1752 sRGB patch corpus.
 *
 * It deliberately leaves luma untouched and maps centered BT.709 Cb/Cr only.
 * The transform is anchored at neutral gray, so black, white, gray text, and
 * smooth grayscale ramps do not acquire a tint. It is an Android-side GPU
 * profile, not a claim that the source has become native Android content.
 */
object AndroidColorProfile {
    const val NAME = "Android sRGB / BT.709 Chroma Balance"
    const val DEFAULT_ENABLED = true

    /**
     * GLSL helper shared by the SurfaceTexture and decoder-fed YUV paths.
     * The uniform keeps A/B switching live without rebuilding the decoder.
     */
    val GLSL_FUNCTION =
        """
        // This helper is also injected ahead of the Qualcomm SGSR1 asset's
        // precision declarations. Keep the snippet self-contained so SGSR1
        // cannot fail compilation merely because the profile is enabled.
        precision mediump float;
        precision mediump int;

        uniform int uAndroidColorProfile;

        vec3 applyAndroidColorProfile(vec3 rgb) {
            if (uAndroidColorProfile == 0) return rgb;

            float cb = -0.114572 * rgb.r - 0.385428 * rgb.g + 0.5 * rgb.b;
            float cr =  0.5      * rgb.r - 0.454153 * rgb.g - 0.045847 * rgb.b;

            // Neutral-anchored fit from the saved 2800x1752 sRGB patch corpus.
            float correctedCb =  1.0313543 * cb - 0.0446065 * cr;
            float correctedCr = -0.0104080 * cb + 1.0615845 * cr;

            return clamp(
                vec3(
                    rgb.r + 1.5748 * (correctedCr - cr),
                    rgb.g - 0.1873 * (correctedCb - cb) - 0.4681 * (correctedCr - cr),
                    rgb.b + 1.8556 * (correctedCb - cb)
                ),
                0.0,
                1.0
            );
        }
        """.trimIndent()
}
