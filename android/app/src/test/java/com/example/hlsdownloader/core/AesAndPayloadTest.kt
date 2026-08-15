package com.example.hlsdownloader.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class AesAndPayloadTest {
    @Test
    fun decryptsAes128CbcPkcs7AndBuildsSequenceIv() {
        val key = ByteArray(16) { it.toByte() }
        val iv = ByteArray(16) { (it + 16).toByte() }
        val plaintext = "HLS encrypted segment".toByteArray()
        val encrypted = Cipher.getInstance("AES/CBC/PKCS5Padding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            doFinal(plaintext)
        }
        assertArrayEquals(plaintext, Aes128Cbc.decrypt(encrypted, key, iv))
        assertArrayEquals(
            byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02, 0x03, 0x04),
            Aes128Cbc.initializationVector(0x01020304uL),
        )
    }

    @Test
    fun sniffsTransportStreamAndRejectsHtml() {
        val ts = transportStreamBytes()
        assertEquals(MediaContainer.TRANSPORT_STREAM, MediaPayloadInspector.detect(ts))
        assertNull(MediaPayloadInspector.detect("<html>login</html>".toByteArray(), "video/mp2t"))
    }

    companion object {
        fun transportStreamBytes(): ByteArray = ByteArray(188 * 3) { 0xff.toByte() }.also { data ->
            repeat(3) { packet ->
                val offset = packet * 188
                data[offset] = 0x47
                data[offset + 1] = if (packet == 0) 0 else 0x01
                data[offset + 2] = if (packet == 0) 0 else 0x00
                data[offset + 3] = 0x10
            }
        }
    }
}
