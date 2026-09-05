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

    data class Entry(
        val host: String,
        val port: Int,
        val token: ByteArray,
        val macName: String,
        val controlPort: Int = (port + 1).coerceAtMost(65535),
    ) {
        override fun equals(other: Any?): Boolean {
            if (other !is Entry) return false
            return host == other.host &&
                port == other.port &&
                controlPort == other.controlPort &&
                macName == other.macName &&
                token.contentEquals(other.token)
        }

        override fun hashCode(): Int =
            ((((host.hashCode() * 31 + port) * 31 + controlPort) * 31 + macName.hashCode()) * 31) +
                token.contentHashCode()
    }

    fun save(entry: Entry) {
        require(entry.port in 1..65535) { "invalid video port" }
        require(entry.controlPort in 1..65535) { "invalid control port" }
        val encrypted = encrypt(entry.token)
        prefs.edit()
            .putString("host", entry.host)
            .putInt("port", entry.port)
            .putInt("control_port", entry.controlPort)
            .putString("token_ciphertext_b64", encode(encrypted.ciphertext))
            .putString("token_iv_b64", encode(encrypted.iv))
            .putString("mac_name", entry.macName)
            .remove("token_b64")
            .apply()
    }

    fun load(): Entry? {
        val host = prefs.getString("host", null) ?: return null
        val port = prefs.getInt("port", -1).takeIf { it in 1..65535 } ?: return null
        val storedControlPort = prefs.getInt("control_port", -1)
        val controlPort =
            if (storedControlPort in 1..65535) {
                storedControlPort
            } else {
                (port + 1).takeIf { it <= 65535 } ?: return null
            }
        val macName = prefs.getString("mac_name", null) ?: "Mac"
        val token =
            loadEncryptedToken()
                ?: loadLegacyToken()?.also { migrate(host, port, controlPort, it, macName) }
        return token?.takeIf { it.size == TOKEN_SIZE }?.let {
            Entry(host, port, it, macName, controlPort)
        }
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    private fun loadEncryptedToken(): ByteArray? {
        val ciphertext = prefs.getString("token_ciphertext_b64", null) ?: return null
        val iv = prefs.getString("token_iv_b64", null) ?: return null
        return try {
            decrypt(decode(ciphertext), decode(iv))
        } catch (_: Exception) {
            // A restored preference without its Keystore key is unusable. Clear
            // only the credential fields and force an explicit re-pair.
            prefs.edit()
                .remove("token_ciphertext_b64")
                .remove("token_iv_b64")
                .remove("token_b64")
                .apply()
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
        controlPort: Int,
        token: ByteArray,
        macName: String,
    ) {
        try {
            save(Entry(host, port, token, macName, controlPort))
        } catch (_: Exception) {
            // Keep the legacy value if Keystore initialization is temporarily
            // unavailable; the next load can retry the migration.
        }
    }

    private data class Encrypted(val ciphertext: ByteArray, val iv: ByteArray)

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

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply {
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
