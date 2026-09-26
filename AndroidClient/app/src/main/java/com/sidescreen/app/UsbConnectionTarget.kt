package com.sidescreen.app

internal data class UsbConnectionTarget(
    val host: String,
    val port: Int,
) {
    companion object {
        const val DEFAULT_HOST = "127.0.0.1"
        const val DEFAULT_PORT = 54321

        fun parse(hostInput: String, portInput: String): ParseResult {
            val host = if (hostInput.isEmpty()) DEFAULT_HOST else hostInput.trim()
            if (host.isEmpty() || host.length > 255 || host.any { it.isWhitespace() || it.code < 0x20 }) {
                return ParseResult.InvalidHost
            }

            val portText = portInput.trim()
            val port = when {
                portText.isEmpty() -> DEFAULT_PORT
                portText.any { it !in '0'..'9' } -> return ParseResult.InvalidPort
                // USB derives the control socket as videoPort + 1.
                else -> portText.toIntOrNull()?.takeIf { it in 1..65534 }
                    ?: return ParseResult.InvalidPort
            }
            val normalizedHost = if (host.equals("localhost", ignoreCase = true)) DEFAULT_HOST else host
            return ParseResult.Valid(UsbConnectionTarget(normalizedHost, port))
        }
    }

    internal sealed interface ParseResult {
        data class Valid(val target: UsbConnectionTarget) : ParseResult
        data object InvalidHost : ParseResult
        data object InvalidPort : ParseResult
    }
}
