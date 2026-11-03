package com.bdsoft.universal_print

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Prints from other Android apps without HTTP. Invisible: it hands the job to
 * the print queue, returns the result and closes.
 *
 * - `com.bdsoft.universal_print.action.PRINT` with extra `payload` (the JSON
 *   body of `POST /api/print`) or `text`; optional `token`, `printer_id`,
 *   `route`, `reference`, `copies`. Use startActivityForResult to get
 *   `job_id` / `status`, or `error`.
 * - Share (ACTION_SEND) of text, an image or a PDF from any app.
 *
 * See docs/API.md, "Android Intent".
 */
class PrintIntentActivity : Activity() {

    companion object {
        const val ACTION_PRINT = "com.bdsoft.universal_print.action.PRINT"
        private const val MAX_BYTES = 10 * 1024 * 1024
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = intent
        io.execute {
            val request = try {
                buildRequest(intent)
            } catch (e: Exception) {
                main.post { finishWith(mapOf("success" to false, "error" to (e.message ?: "Invalid print request"))) }
                return@execute
            }
            main.post {
                PrintEngine.obtain(this)
                val host = PrintEngine.host
                if (host == null) {
                    finishWith(mapOf("success" to false, "error" to "App is not ready"))
                } else {
                    host.submit(request) { finishWith(it) }
                }
            }
        }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    /** `{payload: <json string>, token: <string?>}` for the Dart side. */
    private fun buildRequest(intent: Intent): Map<String, Any?> {
        val payload = when (intent.action) {
            ACTION_PRINT -> {
                val json = intent.getStringExtra("payload")
                val text = intent.getStringExtra("text")
                when {
                    json != null -> JSONObject(json)
                    text != null -> JSONObject().put("document_type", "text").put("content", text)
                    else -> throw IllegalArgumentException("Add a \"payload\" or \"text\" extra")
                }.also { p ->
                    for (key in listOf("printer_id", "route", "reference")) {
                        intent.getStringExtra(key)?.let { p.put(key, it) }
                    }
                    if (intent.hasExtra("copies")) p.put("copies", intent.getIntExtra("copies", 1))
                }
            }
            Intent.ACTION_SEND -> shared(intent)
            else -> throw IllegalArgumentException("Unsupported action ${intent.action}")
        }
        return mapOf("payload" to payload.toString(), "token" to intent.getStringExtra("token"))
    }

    private fun shared(intent: Intent): JSONObject {
        val type = intent.type ?: ""
        if (type.startsWith("text/")) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: throw IllegalArgumentException("Nothing to print")
            return JSONObject().put("document_type", "text").put("content", text)
        }
        val uri = stream(intent) ?: throw IllegalArgumentException("Nothing to print")
        val data = Base64.encodeToString(read(uri), Base64.NO_WRAP)
        return when {
            type == "application/pdf" -> JSONObject().put("document_type", "pdf").put("data", data)
            type.startsWith("image/") -> JSONObject()
                .put("document_type", "elements")
                .put("elements", JSONArray().put(JSONObject().put("type", "image").put("base64", data)))
            else -> throw IllegalArgumentException("Cannot print $type files")
        }
    }

    @Suppress("DEPRECATION")
    private fun stream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun read(uri: Uri): ByteArray {
        val input = contentResolver.openInputStream(uri) ?: throw IllegalArgumentException("Cannot open the file")
        input.use {
            val out = ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = it.read(buf)
                if (n < 0) break
                out.write(buf, 0, n)
                if (out.size() > MAX_BYTES) throw IllegalArgumentException("File is larger than 10 MB")
            }
            return out.toByteArray()
        }
    }

    private fun finishWith(result: Map<*, *>) {
        val ok = result["success"] == true
        val data = Intent()
        for ((k, v) in result) {
            when (v) {
                is String -> data.putExtra(k.toString(), v)
                is Int -> data.putExtra(k.toString(), v)
                is Long -> data.putExtra(k.toString(), v)
                is Boolean -> data.putExtra(k.toString(), v)
            }
        }
        setResult(if (ok) RESULT_OK else RESULT_CANCELED, data)
        val message = if (ok) "Sent to ${result["printer_name"] ?: "printer"}" else "Print failed: ${result["error"]}"
        Toast.makeText(applicationContext, message, if (ok) Toast.LENGTH_SHORT else Toast.LENGTH_LONG).show()
        finish()
    }
}
