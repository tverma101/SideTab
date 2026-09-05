package com.sidescreen.app

import java.io.ByteArrayOutputStream

object AuthHandshake {
    private val REQ_MAGIC = byteArrayOf(0x53, 0x53, 0x57, 0x41) // "SSWA"
    private val RES_MAGIC = byteArrayOf(0x53, 0x53, 0x57, 0x52) // "SSWR"

    enum class ResponseStatus(val code: Byte) {
        OK(0x00),
        INVALID_TOKEN(0x01),
        INVALID_MAGIC(0x02),
        INVALID_NAME(0x03),
        ;

        companion object {
            fun forCode(code: Byte): ResponseStatus? = values().firstOrNull { it.code == code }
        }
    }

    /**
     * Build the wire format request:
     *   [magic 4][token 32][name_len 1][name N]
     *
     * The protocol limit is 64 UTF-8 bytes, not 64 Kotlin characters. Android
     * device model strings can contain multi-byte Unicode, so normalize and
     * truncate at code-point boundaries here rather than forcing every caller
     * to reason about UTF-8 length independently.
     */
    fun encodeRequest(
        token: ByteArray,
        deviceName: String,
    ): ByteArray {
        require(token.size == 32) { "token must be 32 bytes, got ${token.size}" }
        val nameBytes = encodeDeviceName(deviceName)
        return REQ_MAGIC + token + byteArrayOf(nameBytes.size.toByte()) + nameBytes
    }

    private fun encodeDeviceName(deviceName: String): ByteArray {
        val source = deviceName.trim().ifEmpty { DEFAULT_DEVICE_NAME }
        val output = ByteArrayOutputStream(MAX_NAME_BYTES)
        var offset = 0
        while (offset < source.length) {
            val codePoint = source.codePointAt(offset)
            val encoded = String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8)
            if (output.size() + encoded.size > MAX_NAME_BYTES) break
            output.write(encoded)
            offset += Character.charCount(codePoint)
        }

        return output.toByteArray().takeIf { it.isNotEmpty() }
            ?: DEFAULT_DEVICE_NAME.toByteArray(Charsets.UTF_8)
    }

    /**
     * Parse the 5-byte response. Returns null if magic is wrong or buffer is malformed.
     */
    fun parseResponse(bytes: ByteArray): ResponseStatus? {
        if (bytes.size < 5) return null
        for (i in 0..3) if (bytes[i] != RES_MAGIC[i]) return null
        return ResponseStatus.forCode(bytes[4])
    }

    private const val MAX_NAME_BYTES = 64
    private const val DEFAULT_DEVICE_NAME = "Android"
}
