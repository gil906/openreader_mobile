package com.homelab.openreader_native

import android.os.Build
import android.os.Bundle
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var readerFullscreen = false
    private var savedLegacyFlags: Int? = null
    private var readerChannel: MethodChannel? = null
    private val pendingPdfs = linkedMapOf<String, Map<String, String>>()
    private val pendingErrors = mutableListOf<String>()
    private val pdfImports = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        receivePdf(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receivePdf(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        readerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.homelab.openreader_native/reader",
        )
        readerChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "pendingPdfs") {
                result.success(mapOf("pdfs" to pendingPdfs.values.toList(), "errors" to pendingErrors.toList()))
                pendingErrors.clear()
                return@setMethodCallHandler
            }
            if (call.method == "finishPdfImport") {
                val id = call.argument<String>("id")
                val imported = pendingPdfs.remove(id)
                imported?.get("path")?.let { path ->
                    if (!File(path).delete()) Log.w("OpenReader", "Could not remove temporary PDF import.")
                }
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method != "setFullscreen") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val enabled = call.argument<Boolean>("enabled")
            if (enabled == null) {
                result.error("INVALID_ARGUMENT", "Fullscreen requires enabled=true or false.", null)
                return@setMethodCallHandler
            }
            val previous = readerFullscreen
            readerFullscreen = enabled
            if (applyReaderSystemBars()) {
                result.success(null)
            } else {
                readerFullscreen = previous
                result.error("FULLSCREEN_UNAVAILABLE", "System bars controller is unavailable.", null)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun receivePdf(incoming: Intent?) {
        if (incoming == null || incoming.action !in listOf(Intent.ACTION_VIEW, Intent.ACTION_SEND)) return
        val uri = if (incoming.action == Intent.ACTION_SEND) {
            incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: incoming.clipData?.getItemAt(0)?.uri
        } else incoming.data
        if (uri == null || uri.scheme !in listOf("content", "file")) {
            reportImportError("Choose a local PDF or share one from a file provider.")
            return
        }
        pdfImports.execute {
            val id = UUID.randomUUID().toString()
            val target = File(cacheDir, "incoming-$id.pdf")
            try {
                var name = uri.lastPathSegment?.substringAfterLast('/') ?: "Document.pdf"
                if (uri.scheme == "content") {
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (column >= 0) name = cursor.getString(column) ?: name
                        }
                    }
                }
                val input = contentResolver.openInputStream(uri) ?: throw IOException("No PDF read permission.")
                input.use { source ->
                    target.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            val count = source.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > 100L * 1024 * 1024) throw IOException("PDF exceeds the 100 MB import limit.")
                            output.write(buffer, 0, count)
                        }
                    }
                }
                val document = mapOf("id" to id, "path" to target.absolutePath, "name" to name)
                runOnUiThread {
                    pendingPdfs[id] = document
                    readerChannel?.invokeMethod("openPdf", document)
                }
            } catch (error: Exception) {
                target.delete()
                Log.w("OpenReader", "Incoming PDF import failed.", error)
                reportImportError("Could not read the selected PDF. Check its read permission and the 100 MB import limit.")
            }
        }
    }

    private fun reportImportError(message: String) {
        runOnUiThread {
            pendingErrors.add(message)
            readerChannel?.invokeMethod("openPdfError", message)
        }
    }

    override fun onDestroy() {
        pdfImports.shutdown()
        readerChannel = null
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && readerFullscreen && !applyReaderSystemBars()) {
            Log.w("OpenReader", "Could not restore fullscreen system bars.")
        }
    }

    private fun applyReaderSystemBars(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.insetsController ?: return false
            if (readerFullscreen) {
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.systemBars())
            } else {
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_DEFAULT
                controller.show(WindowInsets.Type.systemBars())
            }
        } else {
            applyLegacySystemBars()
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun applyLegacySystemBars() {
        if (readerFullscreen) {
            if (savedLegacyFlags == null) savedLegacyFlags = window.decorView.systemUiVisibility
            window.decorView.systemUiVisibility =
                savedLegacyFlags!! or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        } else {
            savedLegacyFlags?.let { window.decorView.systemUiVisibility = it }
            savedLegacyFlags = null
        }
    }
}
