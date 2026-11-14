package com.example.wa_shield

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-256-GCM with a non-exportable Android Keystore key (alias [KEY_ALIAS]).
 * The key needs no user authentication, so the background listener can use it
 * while the device is unlocked or locked-after-first-unlock.
 *
 * Wire format of one sealed record: base64(NO_WRAP)( iv[12] || ciphertext+tag ).
 */
object KeystoreCrypto {
    private const val KEY_ALIAS = "vesper_queue_key"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_LEN = 12
    private const val TAG_BITS = 128

    @Volatile
    private var cached: SecretKey? = null

    @Synchronized
    private fun key(): SecretKey {
        cached?.let { return it }
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = ks.getKey(KEY_ALIAS, null) as? SecretKey
        val key = existing ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generateKey()
        }
        cached = key
        return key
    }

    fun seal(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val out = ByteArray(iv.size + ct.size)
        System.arraycopy(iv, 0, out, 0, iv.size)
        System.arraycopy(ct, 0, out, iv.size, ct.size)
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    /** Returns null if the record cannot be authenticated/decrypted. */
    fun open(sealed: String): String? = try {
        val all = Base64.decode(sealed, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, all, 0, IV_LEN))
        String(cipher.doFinal(all, IV_LEN, all.size - IV_LEN), Charsets.UTF_8)
    } catch (e: Exception) {
        Log.w("VesperCrypto", "record could not be decrypted (${e.javaClass.simpleName})")
        null
    }
}

/**
 * App-private, encrypted-at-rest, append-only event queue: one sealed JSON
 * event per line in noBackupFilesDir. The native capture side appends; Dart
 * drains (reads all) and then acks the number of events it durably stored, which
 * removes exactly that many lines from the head. Events are idempotent on the
 * Dart side, so a crash between store and ack only causes harmless replays.
 */
class SecureEventQueue(context: Context) {
    private val file = File(context.noBackupFilesDir, "capture_queue.enc")
    private val lock = Any()

    fun append(json: String) {
        val line = KeystoreCrypto.seal(json)
        synchronized(lock) {
            file.appendText(line + "\n", Charsets.UTF_8)
        }
    }

    /** Returns (decrypted events, number of queue lines consumed). Undecryptable lines are skipped. */
    fun readAll(): Pair<List<String>, Int> {
        val lines = synchronized(lock) {
            if (!file.exists()) return emptyList<String>() to 0
            file.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
        }
        val out = ArrayList<String>(lines.size)
        for (l in lines) KeystoreCrypto.open(l)?.let { out.add(it) }
        return out to lines.size
    }

    /** Drops the first [count] lines (those returned by a previous [readAll]). */
    fun ack(count: Int) {
        if (count <= 0) return
        synchronized(lock) {
            if (!file.exists()) return
            val lines = file.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
            val rest = if (count >= lines.size) emptyList() else lines.subList(count, lines.size)
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(if (rest.isEmpty()) "" else rest.joinToString("\n", postfix = "\n"), Charsets.UTF_8)
            if (!tmp.renameTo(file)) {
                file.writeText(tmp.readText(Charsets.UTF_8), Charsets.UTF_8)
                tmp.delete()
            }
        }
    }

    fun size(): Int = synchronized(lock) {
        if (!file.exists()) 0 else file.readLines(Charsets.UTF_8).count { it.isNotBlank() }
    }

    fun clear() {
        synchronized(lock) { file.delete() }
    }
}

/** A single encrypted blob file (used for the chat snapshots). */
class SecureBlob(context: Context, name: String) {
    private val file = File(context.noBackupFilesDir, name)

    @Synchronized
    fun read(): String? = if (!file.exists()) null else KeystoreCrypto.open(file.readText(Charsets.UTF_8).trim())

    @Synchronized
    fun write(plain: String) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(KeystoreCrypto.seal(plain), Charsets.UTF_8)
        if (!tmp.renameTo(file)) {
            file.writeText(tmp.readText(Charsets.UTF_8), Charsets.UTF_8)
            tmp.delete()
        }
    }

    @Synchronized
    fun delete() {
        file.delete()
    }
}
