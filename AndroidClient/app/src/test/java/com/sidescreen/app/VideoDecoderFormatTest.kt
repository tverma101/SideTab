package com.sidescreen.app

import android.media.MediaFormat
import org.junit.Assert.assertEquals
import org.junit.Test

class VideoDecoderFormatTest {
    @Test
    fun absentColorRangeMeansTheHostsLimitedRangeDefault() {
        // KEY_COLOR_RANGE is optional: AOSP only writes "color-range" when the
        // codec reported a value, and the Mac captures in studio swing.
        assertEquals(
            MediaFormat.COLOR_RANGE_LIMITED,
            VideoDecoder.resolveColorRange(null),
        )
    }

    @Test
    fun unknownColorRangeValuesDoNotBecomeFullRange() {
        assertEquals(
            MediaFormat.COLOR_RANGE_LIMITED,
            VideoDecoder.resolveColorRange(0),
        )
        assertEquals(
            MediaFormat.COLOR_RANGE_LIMITED,
            VideoDecoder.resolveColorRange(MediaFormat.COLOR_RANGE_LIMITED),
        )
        assertEquals(
            MediaFormat.COLOR_RANGE_LIMITED,
            VideoDecoder.resolveColorRange(99),
        )
    }

    @Test
    fun onlyAnExplicitFullRangeSelectsTheFullRangeMatrix() {
        assertEquals(
            MediaFormat.COLOR_RANGE_FULL,
            VideoDecoder.resolveColorRange(MediaFormat.COLOR_RANGE_FULL),
        )
    }

    @Test
    fun inputBufferBudgetCoversAWholeRawFrameWithoutExceedingTheHostCap() {
        // KEY_MAX_INPUT_SIZE sizes getInputBuffer(); the host never sends more
        // than 5 MB, so the budget must stay at or below that.
        assertEquals(256 * 1024, VideoDecoder.maxInputSizeBytes(0, 0))
        assertEquals(256 * 1024, VideoDecoder.maxInputSizeBytes(320, 240))
        assertEquals(1920 * 1200 * 3 / 2, VideoDecoder.maxInputSizeBytes(1920, 1200))
        assertEquals(5 * 1024 * 1024, VideoDecoder.maxInputSizeBytes(7680, 4320))
    }
}
