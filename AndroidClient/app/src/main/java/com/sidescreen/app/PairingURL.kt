package com.sidescreen.app

import android.net.Uri
import android.util.Base64

object PairingURL {
    data class Parsed(
        val host: String,
        val port: Int,
        val token: ByteArray,
        val macName: String,
        /** null means the control endpoint follows videoPort + 1. */
        val controlPortOverride: Int?,
    )

    fun parse(url: String): Parsed? {
        val uri =
            try {
                Uri.parse(url)
            } catch (e: Exception) {
                return null
            }
        if (uri.scheme != "sidescreen") return null
        val host = uri.host ?: return null
        val port = uri.port.takeIf { it in 1..65535 } ?: return null
        val tokenB64 = uri.getQueryParameter("t") ?: return null
        val token =
            try {
                Base64.decode(tokenB64, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
            } catch (e: IllegalArgumentException) {
                return null
            }
        if (token.size != 32) return null
        val name = uri.getQueryParameter("name") ?: "Mac"

        // New hosts include c=<controlPort> only when the dedicated control
        // socket does not follow videoPort+1. Keeping the absence meaningful
        // lets Bonjour update a changed video port without freezing the old
        // derived control endpoint in storage.
        val controlPortOverride =
            uri.getQueryParameter("c")?.let { raw ->
                raw.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            }
        if (controlPortOverride == null && port == 65535) return null

        return Parsed(host, port, token, name, controlPortOverride)
    }
}
