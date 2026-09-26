package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionReadinessPolicyTest {
    @Test
    fun unknownMacServerDoesNotLookLikeAFailedConnection() {
        assertEquals(
            ConnectionReadinessState.SERVER_UNCHECKED,
            ConnectionReadinessPolicy.evaluate(localPrerequisitesReady = true, macServerAvailable = null),
        )
    }

    @Test
    fun localSetupAndMacServerFailuresStayDistinct() {
        assertEquals(
            ConnectionReadinessState.LOCAL_SETUP_REQUIRED,
            ConnectionReadinessPolicy.evaluate(localPrerequisitesReady = false, macServerAvailable = true),
        )
        assertEquals(
            ConnectionReadinessState.SERVER_UNAVAILABLE,
            ConnectionReadinessPolicy.evaluate(localPrerequisitesReady = true, macServerAvailable = false),
        )
    }

    @Test
    fun explicitSuccessfulConnectionMakesTheChecklistReady() {
        assertEquals(
            ConnectionReadinessState.READY,
            ConnectionReadinessPolicy.evaluate(localPrerequisitesReady = true, macServerAvailable = true),
        )
    }
}
