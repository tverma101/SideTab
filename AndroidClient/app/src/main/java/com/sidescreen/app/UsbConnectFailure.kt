package com.sidescreen.app

import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * Classification of a failed USB-mode connect attempt.
 *
 * USB failures are Mac-side lifecycle problems: the server is not running,
 * or the ADB bridge is momentarily down (after a USB-debugging crash, an
 * adbd restart, or a cable replug). The Mac app owns `adb reverse` setup and
 * re-establishes it automatically, so the messaging must never send a tablet
 * user to a Mac Terminal.
 */
enum class UsbConnectFailure {
    MAC_SERVER_NOT_RUNNING,
    CANNOT_REACH_MAC,
    TIMED_OUT,
    OTHER;

    companion object {
        fun from(e: Exception): UsbConnectFailure =
            when (e) {
                is ConnectException -> MAC_SERVER_NOT_RUNNING
                is NoRouteToHostException, is UnknownHostException -> CANNOT_REACH_MAC
                is SocketTimeoutException -> TIMED_OUT
                else -> OTHER
            }
    }
}