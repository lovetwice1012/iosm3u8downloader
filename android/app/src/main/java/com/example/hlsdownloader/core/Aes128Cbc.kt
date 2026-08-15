package com.example.hlsdownloader.core

import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object Aes128Cbc {
    fun decrypt(data: ByteArray, key: ByteArray, iv: ByteArray): ByteArray {
        if (key.size != 16 || iv.size != 16 || data.isEmpty() || data.size % 16 != 0) {
            throw HlsException.DecryptionFailed()
        }
        return try {
            Cipher.getInstance("AES/CBC/PKCS5Padding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
                doFinal(data)
            }
        } catch (error: Throwable) {
            throw HlsException.DecryptionFailed(error)
        }
    }

    fun initializationVector(mediaSequence: ULong): ByteArray = ByteArray(16).also { iv ->
        ByteBuffer.wrap(iv, 8, 8).putLong(mediaSequence.toLong())
    }
}
