package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class InputPredictorTest {
    @Test
    fun emptyAndSingleSampleReturnCurrentPosition() {
        val predictor = InputPredictor()

        val (emptyX, emptyY) = predictor.predictPosition(12f)
        assertEquals(0f, emptyX, 0f)
        assertEquals(0f, emptyY, 0f)

        predictor.addSample(0.25f, 0.75f, 1_000_000L)
        val (singleX, singleY) = predictor.predictPosition(12f)
        assertEquals(0.25f, singleX, 0f)
        assertEquals(0.75f, singleY, 0f)
    }

    @Test
    fun predictsFromTwoNewestSamples() {
        val predictor = InputPredictor()
        predictor.addSample(0.10f, 0.20f, 0L)
        predictor.addSample(0.20f, 0.40f, 10_000_000L)

        val (x, y) = predictor.predictPosition(5f)

        assertEquals(0.25f, x, 0.00001f)
        assertEquals(0.50f, y, 0.00001f)
    }

    @Test
    fun ringWrapStillUsesNewestTwoSamples() {
        val predictor = InputPredictor()
        for (i in 0..6) {
            predictor.addSample(
                x = i.toFloat(),
                y = (i * 2).toFloat(),
                timestampNs = i * 10_000_000L,
            )
        }

        val (x, y) = predictor.predictPosition(10f)

        assertEquals(7f, x, 0.00001f)
        assertEquals(14f, y, 0.00001f)
    }

    @Test
    fun subPointOneMillisecondDeltaDoesNotExtrapolate() {
        val predictor = InputPredictor()
        predictor.addSample(1f, 2f, 1_000_000L)
        predictor.addSample(4f, 8f, 1_050_000L)

        val (x, y) = predictor.predictPosition(12f)

        assertEquals(4f, x, 0f)
        assertEquals(8f, y, 0f)
    }

    @Test
    fun resetDropsPreviousVelocityHistory() {
        val predictor = InputPredictor()
        predictor.addSample(0f, 0f, 0L)
        predictor.addSample(1f, 1f, 10_000_000L)
        predictor.reset()
        predictor.addSample(0.3f, 0.7f, 20_000_000L)

        val (x, y) = predictor.predictPosition(12f)
        val (vx, vy) = predictor.getCurrentVelocity()

        assertEquals(0.3f, x, 0f)
        assertEquals(0.7f, y, 0f)
        assertEquals(0f, vx, 0f)
        assertEquals(0f, vy, 0f)
    }

    @Test
    fun currentVelocityUsesNewestSamplesAfterWrap() {
        val predictor = InputPredictor()
        for (i in 0..6) {
            predictor.addSample(
                x = i.toFloat(),
                y = (i * 2).toFloat(),
                timestampNs = i * 100_000_000L,
            )
        }

        val (vx, vy) = predictor.getCurrentVelocity()

        assertEquals(10f, vx, 0.00001f)
        assertEquals(20f, vy, 0.00001f)
    }
}
