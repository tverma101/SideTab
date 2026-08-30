package com.sidescreen.app

/**
 * Small, backwards-compatible admission message for the Android ↔ macOS
 * bridge. The high bit is set on the payload so a V1 macOS parser that only
 * skips unknown bytes cannot mistake it for a video/control message.
 */
internal object ConnectionModeHandshake {
    const val CLIENT_HELLO_TYPE = 16
    const val SERVER_RESULT_TYPE = 17

    private const val PAYLOAD_MARKER = 0x80

    enum class ResultCode(val wireValue: Int) {
        ACCEPTED(0),
        WRONG_MODE(1),
        WRONG_TRANSPORT(2),
        INVALID_HELLO(3),
        ;

        companion object {
            fun fromWireValue(value: Int): ResultCode? =
                entries.firstOrNull { it.wireValue == value }
        }
    }

    data class ServerResult(
        val code: ResultCode,
        val expectedMode: ConnectionMode,
    ) {
        val accepted: Boolean
            get() = code == ResultCode.ACCEPTED
    }

    fun encodeClientHello(mode: ConnectionMode): ByteArray =
        byteArrayOf(
            CLIENT_HELLO_TYPE.toByte(),
            (PAYLOAD_MARKER or mode.wireValue()).toByte(),
        )

    fun decodeClientHello(type: Int, payload: Int): ConnectionMode? {
        if (type != CLIENT_HELLO_TYPE || payload and PAYLOAD_MARKER == 0) return null
        return ConnectionMode.fromWireValue(payload and PAYLOAD_MARKER.inv())
    }

    fun encodeServerResult(
        code: ResultCode,
        expectedMode: ConnectionMode,
    ): ByteArray =
        byteArrayOf(
            SERVER_RESULT_TYPE.toByte(),
            code.wireValue.toByte(),
            (PAYLOAD_MARKER or expectedMode.wireValue()).toByte(),
        )

    fun decodeServerResult(
        type: Int,
        resultCode: Int,
        encodedExpectedMode: Int,
    ): ServerResult? {
        if (type != SERVER_RESULT_TYPE || encodedExpectedMode and PAYLOAD_MARKER == 0) return null
        val code = ResultCode.fromWireValue(resultCode) ?: return null
        val expectedMode = ConnectionMode.fromWireValue(encodedExpectedMode and PAYLOAD_MARKER.inv()) ?: return null
        return ServerResult(code, expectedMode)
    }

    fun failureMessage(result: ServerResult): String =
        when (result.code) {
            ResultCode.ACCEPTED -> "Mac accepted ${result.expectedMode.displayName} mode"
            ResultCode.WRONG_MODE ->
                "Mac is serving ${result.expectedMode.displayName} mode. Switch the Mac app to " +
                    "${result.expectedMode.displayName} before connecting."
            ResultCode.WRONG_TRANSPORT ->
                "Mac rejected this route. Use the ${result.expectedMode.displayName} connection path."
            ResultCode.INVALID_HELLO -> "Mac rejected an invalid connection-mode handshake."
        }

}
