package com.homelab.openreader_native

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import androidx.core.content.FileProvider
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
            when (call.method) {
                "pendingPdfs" -> {
                    result.success(mapOf("pdfs" to pendingPdfs.values.toList(), "errors" to pendingErrors.toList()))
                    pendingErrors.clear()
                }
                "finishPdfImport" -> {
                    val id = call.argument<String>("id")
                    val imported = pendingPdfs.remove(id)
                    imported?.get("path")?.let { path ->
                        if (!File(path).delete()) Log.w("OpenReader", "Could not remove temporary PDF import.")
                    }
                    result.success(null)
                }
                "saveToDownloads" -> {
                    val sourcePath = call.argument<String>("path")
                    val rawName = call.argument<String>("fileName") ?: "Document.pdf"
                    val mimeType = call.argument<String>("mimeType") ?: "application/pdf"
                    if (sourcePath.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Missing source file path.", null)
                        return@setMethodCallHandler
                    }
                    pdfImports.execute {
                        try {
                            val savedLocation = saveFileToDownloads(File(sourcePath), sanitizeFileName(rawName), mimeType)
                            runOnUiThread { result.success(savedLocation) }
                        } catch (error: Exception) {
                            Log.w("OpenReader", "saveToDownloads failed.", error)
                            runOnUiThread { result.error("SAVE_FAILED", error.message ?: "Could not save file.", null) }
                        }
                    }
                }
                "shareFile" -> {
                    val sourcePath = call.argument<String>("path")
                    val rawName = call.argument<String>("fileName") ?: "Document.pdf"
                    val mimeType = call.argument<String>("mimeType") ?: "application/pdf"
                    val title = call.argument<String>("title") ?: rawName
                    if (sourcePath.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Missing source file path.", null)
                        return@setMethodCallHandler
                    }
                    pdfImports.execute {
                        try {
                            val cleanName = sanitizeFileName(rawName)
                            val shareDir = File(cacheDir, "shared").apply { mkdirs() }
                            val targetFile = File(shareDir, cleanName)
                            val sourceFile = File(sourcePath)
                            if (sourceFile.canonicalPath != targetFile.canonicalPath) {
                                sourceFile.copyTo(targetFile, overwrite = true)
                            }
                            val uri = FileProvider.getUriForFile(
                                this@MainActivity,
                                "$packageName.fileprovider",
                                targetFile,
                            )
                            runOnUiThread {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    type = mimeType
                                    putExtra(Intent.EXTRA_STREAM, uri)
                                    putExtra(Intent.EXTRA_TITLE, title)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                startActivity(Intent.createChooser(sendIntent, title))
                                result.success(true)
                            }
                        } catch (error: Exception) {
                            Log.w("OpenReader", "shareFile failed.", error)
                            runOnUiThread { result.error("SHARE_FAILED", error.message ?: "Could not share file.", null) }
                        }
                    }
                }
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val title = call.argument<String>("title") ?: "Share passage"
                    if (text.isBlank()) {
                        result.error("INVALID_ARGUMENT", "Nothing to share.", null)
                        return@setMethodCallHandler
                    }
                    val sendIntent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_SUBJECT, title)
                        putExtra(Intent.EXTRA_TEXT, text)
                    }
                    startActivity(Intent.createChooser(sendIntent, title))
                    result.success(true)
                }
                "setFullscreen" -> {
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
                else -> result.notImplemented()
            }
        }
    }

    private fun sanitizeFileName(raw: String): String {
        val cleaned = raw.replace(Regex("[\\\\/:*?\"<>|]"), "_").trim()
        return if (cleaned.isEmpty()) "Document.pdf" else cleaned
    }

    private fun saveFileToDownloads(source: File, fileName: String, mimeType: String): String {
        if (!source.exists()) throw IOException("Source file does not exist.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("MediaStore refused to create download entry.")
            try {
                contentResolver.openOutputStream(uri)?.use { out ->
                    source.inputStream().use { input -> input.copyTo(out) }
                } ?: throw IOException("Could not open Download output stream.")
                val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                contentResolver.update(uri, done, null, null)
                return "Downloads/$fileName"
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
        } else {
            @Suppress("DEPRECATION")
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            dir.mkdirs()
            val out = File(dir, fileName)
            source.copyTo(out, overwrite = true)
            return out.absolutePath
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
