package com.sidescreen.app

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * Persists paired-host route metadata while keeping the long-lived pairing
 * credential encrypted with a non-exportable AndroidKeyStore key.
 *
 * Existing installs are migrated once from the historical Base64 plaintext
 * entry. A failed migration/decryption fails closed: the user must re-pair
 * rather than silently falling back to recoverable plaintext credentials.
 */
class PairedHostStorage(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val keyLock = Any()
    private val mutationLock = Any()
    private val mutationEpoch = AtomicLong(0L)

    /** Avoid repeated KeyStore decrypts from legacy UI code during one process lifetime. */
    @Volatile
    private var cachedEntry: Entry? = null

    data class Entry(val host: String, val port: Int, val token: ByteArray, val macName: String) {
        override fun equals(other: Any?): Boolean {
            if (other !is Entry) return false
            return host == other.host && port == other.port && macName == other.macName &&
                token.contentEquals(other.token)
        }

        override fun hashCode(): Int =
            ((host.hashCode() * 31 + port) * 31 + macName.hashCode()) * 31 + token.contentHashCode()

        fun defensiveCopy(): Entry = copy(token = token.copyOf())
    }

    /**
     * Returns false instead of ever falling back to plaintext persistence.
     * Callers may continue the in-memory connection attempt, but the pairing
     * will not survive restart until secure persistence succeeds.
     *
     * Crypto/key generation deliberately happens outside [mutationLock]. The
     * final commit is serialized and guarded by [mutationEpoch], so a later
     * Forget or newer QR scan wins even if this save was already running.
     */
    fun save(entry: Entry): Boolean {
        if (entry.token.size != TOKEN_BYTES) {
            DiagLog.log(TAG, "Refusing to persist invalid pairing credential length")
            return false
        }

        val operation = mutationEpoch.incrementAndGet()
        return try {
            val envelope = PairingSecretEnvelope.encrypt(entry.token, getOrCreateKey())
            synchronized(mutationLock) {
                if (mutationEpoch.get() != operation) {
                    DiagLog.log(TAG, "Discarding superseded pairing persistence operation")
                    return@synchronized false
                }
                val committed =
                    prefs.edit()
                        .putInt(KEY_SCHEMA_VERSION, CURRENT_SCHEMA_VERSION)
                        .putString(KEY_HOST, entry.host)
                        .putInt(KEY_PORT, entry.port)
                        .putString(KEY_TOKEN_IV_B64, encode(envelope.iv))
                        .putString(KEY_TOKEN_CIPHERTEXT_B64, encode(envelope.ciphertext))
                        .putString(KEY_MAC_NAME, entry.macName)
                        .remove(KEY_LEGACY_TOKEN_B64)
                        .commit()
                if (committed && mutationEpoch.get() == operation) {
                    cachedEntry = entry.defensiveCopy()
                }
                committed && mutationEpoch.get() == operation
            }
        } catch (e: Exception) {
            DiagLog.log(TAG, "Secure pairing persistence failed: ${e.javaClass.simpleName}")
            false
        }
    }

    fun load(): Entry? {
        cachedEntry?.let { return it.defensiveCopy() }

        val host = prefs.getString(KEY_HOST, null) ?: return null
        val port = prefs.getInt(KEY_PORT, -1).takeIf { it > 0 } ?: return null
        val macName = prefs.getString(KEY_MAC_NAME, null) ?: "Mac"

        val hasEncryptedMaterial =
            prefs.contains(KEY_TOKEN_IV_B64) || prefs.contains(KEY_TOKEN_CIPHERTEXT_B64)
        if (hasEncryptedMaterial) {
            val token = readEncryptedToken()
            if (token == null || token.size != TOKEN_BYTES) {
                invalidateStoredPairing("encrypted credential invalid or undecryptable")
                return null
            }
            return Entry(host, port, token, macName).also { cachedEntry = it.defensiveCopy() }
        }

        // One-time migration from the historical Base64 plaintext preference.
        val legacyB64 = prefs.getString(KEY_LEGACY_TOKEN_B64, null) ?: return null
        val legacyToken = decode(legacyB64)
        if (legacyToken == null || legacyToken.size != TOKEN_BYTES) {
            invalidateStoredPairing("legacy credential invalid")
            return null
        }

        val entry = Entry(host, port, legacyToken, macName)
        if (!save(entry)) {
            // Do not leave a usable plaintext credential behind if secure
            // migration is unavailable for any reason.
            invalidateStoredPairing("legacy credential migration failed")
            return null
        }
        DiagLog.log(TAG, "Migrated paired-host credential to AndroidKeyStore-backed storage")
        return entry.defensiveCopy()
    }

    fun clear() {
        // Invalidate in-flight encryptions before waiting for the commit lock.
        // If an old save committed first, this clear executes after and removes
        // it. If clear wins first, that save sees a stale epoch and cannot
        // resurrect the pairing.
        mutationEpoch.incrementAndGet()
        synchronized(mutationLock) {
            cachedEntry = null
            prefs.edit().clear().commit()
            deleteKey()
        }
    }

    private fun readEncryptedToken(): ByteArray? {
        val iv = prefs.getString(KEY_TOKEN_IV_B64, null)?.let(::decode) ?: return null
        val ciphertext = prefs.getString(KEY_TOKEN_CIPHERTEXT_B64, null)?.let(::decode) ?: return null

        return try {
            PairingSecretEnvelope.decrypt(
                PairingSecretEnvelope.Envelope(iv = iv, ciphertext = ciphertext),
                getOrCreateKey(),
            )
        } catch (e: Exception) {
            DiagLog.log(TAG, "Pairing credential decrypt failed: ${e.javaClass.simpleName}")
            null
        }
    }

    private fun getOrCreateKey(): SecretKey = synchronized(keyLock) {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return@synchronized it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        generator.generateKey()
    }

    private fun invalidateStoredPairing(reason: String) {
        DiagLog.log(TAG, "Discarding stored pairing: $reason")
        mutationEpoch.incrementAndGet()
        synchronized(mutationLock) {
            cachedEntry = null
            prefs.edit().clear().commit()
            deleteKey()
        }
    }

    private fun deleteKey() {
        runCatching {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            if (keyStore.containsAlias(KEY_ALIAS)) {
                keyStore.deleteEntry(KEY_ALIAS)
            }
        }.onFailure { e ->
            DiagLog.log(TAG, "Pairing key deletion failed: ${e.javaClass.simpleName}")
        }
    }

    private fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.NO_PADDING)

    private fun decode(value: String): ByteArray? =
        try {
            Base64.decode(value, Base64.NO_WRAP or Base64.NO_PADDING)
        } catch (_: IllegalArgumentException) {
            null
        }

    private companion object {
        const val TAG = "PairedHostStorage"
        const val PREFS_NAME = "paired_host"
        const val CURRENT_SCHEMA_VERSION = 2
        const val TOKEN_BYTES = 32
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "com.sidescreen.app.pairing.aes.v1"
        const val KEY_SCHEMA_VERSION = "schema_version"
        const val KEY_HOST = "host"
        const val KEY_PORT = "port"
        const val KEY_MAC_NAME = "mac_name"
        const val KEY_TOKEN_IV_B64 = "token_iv_b64"
        const val KEY_TOKEN_CIPHERTEXT_B64 = "token_ciphertext_b64"
        const val KEY_LEGACY_TOKEN_B64 = "token_b64"
    }
}
