package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import javax.crypto.AEADBadTagException
import javax.crypto.KeyGenerator

class PairingSecretEnvelopeTest {
    private fun key() =
        KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test
    fun roundTripPreservesSecretWithoutStoringPlaintext() {
        val secret = ByteArray(32) { index -> (index * 7 + 3).toByte() }
        val sharedKey = key()
        val envelope = PairingSecretEnvelope.encrypt(secret, sharedKey)

        assertFalse(envelope.ciphertext.contentEquals(secret))
        assertArrayEquals(secret, PairingSecretEnvelope.decrypt(envelope, sharedKey))
    }

    @Test
    fun ciphertextTamperingIsRejected() {
        val sharedKey = key()
        val envelope = PairingSecretEnvelope.encrypt(ByteArray(32) { 0x5A.toByte() }, sharedKey)
        val tampered = envelope.ciphertext.copyOf().also {
            it[it.lastIndex] = (it.last().toInt() xor 0x01).toByte()
        }

        assertThrows(AEADBadTagException::class.java) {
            PairingSecretEnvelope.decrypt(envelope.copy(ciphertext = tampered), sharedKey)
        }
    }
}
