package com.sidescreen.app

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Stores the pairing credential encrypted with an Android Keystore key. */
class PairedHostStorage(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("paired_host", Context.MODE_PRIVATE)
    private val mutationLock = Any()
    private val keyLock = Any()
    private var mutationGeneration = 0L

    data class Entry(
        val host: String,
        val port: Int,
        val token: ByteArray,
        val macName: String,
        /** null means derive the dedicated control endpoint as videoPort + 1. */
        val controlPortOverride: Int? = null,
    ) {
        fun effectiveControlPort(): Int? =
            controlPortOverride ?: (port + 1).takeIf { it <= 65535 }

        override fun equals(other: Any?): Boolean {
            if (other !is Entry) return false
            return host == other.host &&
                port == other.port &&
                controlPortOverride == other.controlPortOverride &&
                macName == other.macName &&
                token.contentEquals(other.token)
        }

        override fun hashCode(): Int =
            ((((host.hashCode() * 31 + port) * 31 + (controlPortOverride ?: 0)) * 31 + macName.hashCode()) * 31) +
                token.contentHashCode()
    }

    fun save(entry: Entry) {
        require(entry.port in 1..65535) { "invalid video port" }
        require(entry.effectiveControlPort() != null) { "invalid derived control port" }
        entry.controlPortOverride?.let {
            require(it in 1..65535) { "invalid control port override" }
        }

        // Mark this save before doing KeyStore work. If Forget Pairing or a
        // newer save happens while encryption is in flight, this operation is
        // stale and must not be allowed to resurrect/overwrite a pairing.
        val operationGeneration = synchronized(mutationLock) {
            mutationGeneration += 1
            mutationGeneration
        }

        val encrypted =
            try {
                encrypt(entry.token)
            } catch (e: Exception) {
                DiagLog.log("PAIR", "Secure pairing persistence failed: ${e.javaClass.simpleName}")
                return
            }

        synchronized(mutationLock) {
            if (operationGeneration != mutationGeneration) {
                DiagLog.log("PAIR", "Discarding superseded pairing persistence operation")
                return@synchronized
            }

            pairingEditor(entry, encrypted).apply()
        }
    }

    fun load(): Entry? = synchronized(mutationLock) {
        val host = prefs.getString("host", null) ?: return@synchronized null
        val port = prefs.getInt("port", -1).takeIf { it in 1..65535 } ?: return@synchronized null
        val storedControlOverride = prefs.getInt("control_port_override", -1)
        val controlPortOverride = storedControlOverride.takeIf { it in 1..65535 }
        if (controlPortOverride == null && port == 65535) return@synchronized null

        val macName = prefs.getString("mac_name", null) ?: "Mac"
        val encryptedToken = loadEncryptedToken()
        if (encryptedToken != null) {
            return@synchronized encryptedToken.takeIf { it.size == TOKEN_SIZE }?.let {
                Entry(host, port, it, macName, controlPortOverride)
            }
        }

        val legacyToken = loadLegacyToken()
        if (legacyToken == null) {
            if (prefs.contains("token_b64")) {
                invalidateStoredPairing("legacy credential invalid")
            }
            return@synchronized null
        }

        if (!migrate(host, port, controlPortOverride, legacyToken, macName)) {
            // Never keep using a recoverable plaintext credential if secure
            // migration cannot be committed. Re-pairing is safer than silently
            // continuing with a token that remains in SharedPreferences.
            invalidateStoredPairing("legacy credential migration failed")
            return@synchronized null
        }

        Entry(host, port, legacyToken, macName, controlPortOverride)
    }

    fun clear() {
        synchronized(mutationLock) {
            // Invalidate saves already encrypting before removing anything.
            // A stale save will fail its generation check after this returns.
            mutationGeneration += 1

            // Forget Pairing is a security-sensitive user action. Use a
            // synchronous preference commit so an immediate process exit
            // cannot leave the legacy plaintext token or ciphertext on disk.
            if (!prefs.edit().clear().commit()) {
                DiagLog.log("PAIR", "Pairing preference deletion did not commit")
            }

            // The ciphertext is not the only persistent artifact: remove the
            // non-exportable AES key as well so the old credential cannot be
            // recovered from a restored/stale preference file.
            deleteKey()
        }
    }

    private fun loadEncryptedToken(): ByteArray? {
        val ciphertext = prefs.getString("token_ciphertext_b64", null) ?: return null
        val iv = prefs.getString("token_iv_b64", null) ?: return null
        return try {
            decrypt(decode(ciphertext), decode(iv))
        } catch (e: Exception) {
            DiagLog.log("PAIR", "Stored pairing credential could not be decrypted: ${e.javaClass.simpleName}")
            invalidateStoredPairing("encrypted credential invalid or undecryptable")
            null
        }
    }

    private fun loadLegacyToken(): ByteArray? =
        prefs.getString("token_b64", null)?.let {
            try {
                Base64.decode(it, Base64.NO_WRAP or Base64.NO_PADDING)
            } catch (_: IllegalArgumentException) {
                null
            }
        }?.takeIf { it.size == TOKEN_SIZE }

    private fun migrate(
        host: String,
        port: Int,
        controlPortOverride: Int?,
        token: ByteArray,
        macName: String,
    ): Boolean {
        val entry = Entry(host, port, token, macName, controlPortOverride)
        val operationGeneration = synchronized(mutationLock) {
            mutationGeneration += 1
            mutationGeneration
        }

        val encrypted =
            try {
                encrypt(token)
            } catch (e: Exception) {
                DiagLog.log("PAIR", "Legacy pairing migration failed: ${e.javaClass.simpleName}")
                return false
            }

        return synchronized(mutationLock) {
            if (operationGeneration != mutationGeneration) {
                DiagLog.log("PAIR", "Discarding superseded legacy pairing migration")
                return@synchronized false
            }

            // Migration is a one-time security boundary. Commit synchronously
            // so success means ciphertext/IV are durable and token_b64 is gone
            // before load() returns the credential to a live session.
            val committed = pairingEditor(entry, encrypted).commit()
            if (!committed) {
                DiagLog.log("PAIR", "Legacy pairing migration did not commit")
            }
            committed
        }
    }

    private fun invalidateStoredPairing(reason: String) {
        synchronized(mutationLock) {
            mutationGeneration += 1
            DiagLog.log("PAIR", "Discarding stored pairing: $reason")
            if (!prefs.edit().clear().commit()) {
                DiagLog.log("PAIR", "Invalid pairing cleanup did not commit")
            }
            deleteKey()
        }
    }

    private data class Encrypted(val ciphertext: ByteArray, val iv: ByteArray)

    private fun pairingEditor(
        entry: Entry,
        encrypted: Encrypted,
    ): SharedPreferences.Editor {
        val editor =
            prefs.edit()
                .putString("host", entry.host)
                .putInt("port", entry.port)
                .putString("token_ciphertext_b64", encode(encrypted.ciphertext))
                .putString("token_iv_b64", encode(encrypted.iv))
                .putString("mac_name", entry.macName)
                .remove("token_b64")
        if (entry.controlPortOverride != null) {
            editor.putInt("control_port_override", entry.controlPortOverride)
        } else {
            editor.remove("control_port_override")
        }
        // Remove the short-lived absolute-port key from the stabilization
        // branch if a build containing it was ever installed.
        return editor.remove("control_port")
    }

    private fun encrypt(plain: ByteArray): Encrypted {
        require(plain.size == TOKEN_SIZE) { "pairing token must be 32 bytes" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Encrypted(cipher.doFinal(plain), cipher.iv)
    }

    private fun decrypt(ciphertext: ByteArray, iv: ByteArray): ByteArray {
        require(iv.size == GCM_IV_SIZE) { "invalid pairing token IV" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun key(): SecretKey = synchronized(keyLock) {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return@synchronized it }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setUserAuthenticationRequired(false)
                    .build(),
            )
        }.generateKey()
    }

    private fun deleteKey() = synchronized(keyLock) {
        try {
            val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (store.containsAlias(KEY_ALIAS)) {
                store.deleteEntry(KEY_ALIAS)
            }
        } catch (e: Exception) {
            // Preferences are already durably cleared. Keep this observable so
            // target-device validation can catch a KeyStore deletion failure.
            DiagLog.log("PAIR", "Pairing key deletion failed: ${e.javaClass.simpleName}")
        }
    }

    private fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.NO_PADDING)

    private fun decode(value: String): ByteArray =
        Base64.decode(value, Base64.NO_WRAP or Base64.NO_PADDING)

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "sidescreen_pairing_token"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TOKEN_SIZE = 32
        private const val GCM_IV_SIZE = 12
        private const val GCM_TAG_BITS = 128
    }
}
