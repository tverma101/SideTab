package com.sidescreen.app

import android.content.Context
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairedHostStorageInstrumentedTest {
    private lateinit var context: Context
    private lateinit var storage: PairedHostStorage

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        storage = PairedHostStorage(context)
        storage.clear()
    }

    @After
    fun tearDown() {
        storage.clear()
    }

    @Test
    fun saveUsesEncryptedFieldsAndRoundTripsThroughAndroidKeyStore() {
        val token = ByteArray(32) { index -> (index * 11 + 5).toByte() }
        val entry = PairedHostStorage.Entry("192.168.1.22", 54321, token, "Test Mac")

        assertTrue(storage.save(entry))

        val prefs = context.getSharedPreferences("paired_host", Context.MODE_PRIVATE)
        assertFalse(prefs.contains("token_b64"))
        assertNotNull(prefs.getString("token_iv_b64", null))
        assertNotNull(prefs.getString("token_ciphertext_b64", null))

        val restored = storage.load()
        assertNotNull(restored)
        assertArrayEquals(token, restored!!.token)
    }

    @Test
    fun legacyPlaintextTokenMigratesOnceAndIsRemoved() {
        val token = ByteArray(32) { index -> (255 - index).toByte() }
        val prefs = context.getSharedPreferences("paired_host", Context.MODE_PRIVATE)
        prefs.edit()
            .putString("host", "10.0.0.8")
            .putInt("port", 54321)
            .putString("mac_name", "Legacy Mac")
            .putString(
                "token_b64",
                Base64.encodeToString(token, Base64.NO_WRAP or Base64.NO_PADDING),
            )
            .commit()

        val restored = storage.load()

        assertNotNull(restored)
        assertArrayEquals(token, restored!!.token)
        assertFalse(prefs.contains("token_b64"))
        assertNotNull(prefs.getString("token_ciphertext_b64", null))
    }
}
