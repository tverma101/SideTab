package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

class UsbConnectFailureTest {
    @Test
    fun refusedConnectionIsMacServerNotRunning() {
        val failure = UsbConnectFailure.from(ConnectException("Connection refused"))

        assertEquals(UsbConnectFailure.MAC_SERVER_NOT_RUNNING, failure)
    }

    @Test
    fun unroutableOrUnknownHostIsCannotReachMac() {
        assertEquals(
            UsbConnectFailure.CANNOT_REACH_MAC,
            UsbConnectFailure.from(NoRouteToHostException("no route to host")),
        )
        assertEquals(
            UsbConnectFailure.CANNOT_REACH_MAC,
            UsbConnectFailure.from(UnknownHostException("host")),
        )
    }

    @Test
    fun readTimeoutIsTimedOut() {
        val failure = UsbConnectFailure.from(SocketTimeoutException("Read timed out"))

        assertEquals(UsbConnectFailure.TIMED_OUT, failure)
    }

    @Test
    fun anyOtherFailureIsOther() {
        assertEquals(UsbConnectFailure.OTHER, UsbConnectFailure.from(IOException("reset by peer")))
    }
}