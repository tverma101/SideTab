package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CodecCapabilitiesSizeTest {
    private fun decoder(
        maxWidth: Int,
        maxHeight: Int,
        heightLimit: Int = maxHeight,
    ): (Int, Int) -> Boolean = { w, h -> w <= maxWidth && h <= heightLimit }

    @Test
    fun acceptsTheAdvertisedMaximumWhenItIsReal() {
        val chosen =
            selectLargestSupportedSize(
                widthBounds = 64..1920,
                heightBounds = 64..1080,
                isSupported = decoder(maxWidth = 1920, maxHeight = 1080),
            )

        assertEquals(1920 to 1080, chosen)
    }

    @Test
    fun neverAdvertisesARectangleMadeOfTwoIndependentMaxima() {
        // Width<=1920 and height<=2160 do not imply 1920x2160 is decodable; the
        // host treats the advertised pair as authoritative and would encode at
        // a size this decoder rejects.
        val chosen =
            selectLargestSupportedSize(
                widthBounds = 64..1920,
                heightBounds = 64..2160,
                isSupported = decoder(maxWidth = 1920, maxHeight = 1080),
            )

        assertEquals(1920 to 1080, chosen)
    }

    @Test
    fun fallsBackThroughAlignedAndCommonSizesWhenTheMaximumIsRejected() {
        val chosen =
            selectLargestSupportedSize(
                widthBounds = 64..1921,
                heightBounds = 64..1081,
                isSupported = decoder(maxWidth = 1920, maxHeight = 1080),
            )

        assertEquals(1920 to 1080, chosen)
    }

    @Test
    fun returnsNullWhenNothingInTheLadderIsSupported() {
        val chosen =
            selectLargestSupportedSize(
                widthBounds = 64..1920,
                heightBounds = 64..1080,
                isSupported = { _, _ -> false },
            )

        assertNull(chosen)
    }

    @Test
    fun unboundedOrAbsentDimensionYieldsNoAdvertisedLimit() {
        // AOSP reports Range(0, 0) for a dimension the codec does not limit.
        assertNull(
            selectLargestSupportedSize(0..0, 64..1080) { w, h -> w > 0 && h in 64..1080 },
        )
        assertNull(selectLargestSupportedSize(null, 64..1080) { _, _ -> true })
        assertNull(selectLargestSupportedSize(64..1920, null) { _, _ -> true })
        assertNull(selectLargestSupportedSize(64..0, 64..0) { _, _ -> true })
    }
}
