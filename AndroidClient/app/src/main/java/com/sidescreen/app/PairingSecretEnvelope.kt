package com.sidescreen.app

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small, platform-independent AES-GCM envelope used for the long-lived pairing
 * credential. Key creation/storage belongs to [PairedHostStorage]; keeping the
 * crypto primitive independent lets JVM tests exercise tamper detection without
 * pretending AndroidKeyStore exists in a host-side test process.
 */
internal object PairingSecretEnvelope {
    private const val GCM_TAG_BITS = 128
    private const val IV_BYTES = 12
    private val AAD = "SideScreen pairing credential v1".toByteArray(Charsets.UTF_8)

    data class Envelope(
        val iv: ByteArray,
        val ciphertext: ByteArray,
    )

    fun encrypt(
        plaintext: ByteArray,
        key: SecretKey,
        random: SecureRandom = SecureRandom(),
    ): Envelope {
        require(plaintext.isNotEmpty()) { "pairing secret must not be empty" }
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        cipher.updateAAD(AAD)
        return Envelope(iv = iv, ciphertext = cipher.doFinal(plaintext))
    }

    fun decrypt(
        envelope: Envelope,
        key: SecretKey,
    ): ByteArray {
        require(envelope.iv.size == IV_BYTES) { "invalid pairing IV" }
        require(envelope.ciphertext.isNotEmpty()) { "invalid pairing ciphertext" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, envelope.iv))
        cipher.updateAAD(AAD)
        return cipher.doFinal(envelope.ciphertext)
    }
}
