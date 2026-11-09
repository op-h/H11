package app.midad.midad

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.security.keystore.KeyGenParameterSpec
import android.webkit.MimeTypeMap
import java.io.File
import android.security.keystore.KeyProperties
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Seals Midad's secrets (device key, pairing data, translation key) with an
 * AES-256-GCM key that lives inside the Android Keystore and never leaves it.
 */
class MainActivity : FlutterActivity() {
    private val alias = "midad-vault-v1"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "midad/keystore")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "seal" -> result.success(seal(call.arguments as ByteArray))
                        "open" -> result.success(open(call.arguments as ByteArray))
                        "saveToDownloads" -> {
                            val a = call.arguments as Map<*, *>
                            val src = File(a["path"] as String)
                            val name = a["name"] as String
                            // Large videos: copy off the main thread.
                            Thread {
                                try {
                                    val where = saveToDownloads(src, name)
                                    runOnUiThread { result.success(where) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("save", e.message, null) }
                                }
                            }.start()
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("keystore", e.message, null)
                }
            }
    }

    /** Copies a file into the public Downloads/H11 folder, byte for byte. */
    private fun saveToDownloads(src: File, name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/H11")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Could not create the file in Downloads")
            contentResolver.openOutputStream(uri)!!.use { out ->
                src.inputStream().use { it.copyTo(out, 1 shl 16) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return "Downloads/H11"
        }
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "H11")
        dir.mkdirs()
        var f = File(dir, name)
        var i = 1
        while (f.exists()) {
            f = File(dir, "${name.substringBeforeLast('.')} ($i)${if (ext.isEmpty()) "" else ".$ext"}")
            i++
        }
        src.copyTo(f)
        return "Downloads/H11"
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun seal(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return c.iv + c.doFinal(plain)
    }

    private fun open(sealed: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed.copyOfRange(0, 12)))
        return c.doFinal(sealed.copyOfRange(12, sealed.size))
    }
}
