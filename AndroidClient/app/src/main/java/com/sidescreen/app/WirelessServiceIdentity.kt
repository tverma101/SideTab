package com.sidescreen.app

import java.security.MessageDigest

/** Stable Bonjour instance identity derived from (but not revealing) the pairing token. */
object WirelessServiceIdentity {
    const val SERVICE_TYPE = "_sidescreen._tcp."

    fun nameForToken(token: ByteArray): String {
        require(token.size == 32) { "pairing token must be 32 bytes" }
        val digest = MessageDigest.getInstance("SHA-256").digest(token)
        val suffix = digest.take(8).joinToString(separator = "") { byte ->
            "%02x".format(byte.toInt() and 0xFF)
        }
        return "SideScreen-$suffix"
    }
}
