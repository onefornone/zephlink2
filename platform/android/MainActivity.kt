package app.zephlink.zephlink

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingFilePickerResult: MethodChannel.Result? = null
    private var pendingFolderPickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScreenBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zephlink/keepalive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                        }
                        val intent = Intent(this, KeepAliveService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this, KeepAliveService::class.java))
                        result.success(true)
                    }
                    "batteryExempt" -> {
                        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(power.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestBatteryExempt" -> {
                        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (!power.isIgnoringBatteryOptimizations(packageName)) {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            intent.data = Uri.parse("package:$packageName")
                            startActivity(intent)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "zephlink/notification_forwarding"
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hasAccess" -> result.success(
                        NotificationForwardingStore.hasAccess(this)
                    )
                    "openSettings" -> {
                        NotificationForwardingStore.openSettings(this)
                        result.success(null)
                    }
                    "setEnabled" -> {
                        NotificationForwardingStore.setEnabled(
                            this,
                            call.argument<Boolean>("enabled") ?: false
                        )
                        result.success(null)
                    }
                    "pending" -> result.success(
                        NotificationForwardingStore.pending()
                    )
                    "acknowledge" -> {
                        val eventId = call.argument<String>("eventId")
                        if (eventId == null) {
                            result.error(
                                "invalid_event",
                                "Missing notification event identifier.",
                                null
                            )
                        } else {
                            NotificationForwardingStore.acknowledge(eventId)
                            result.success(null)
                        }
                    }
                    "reply" -> {
                        val id = call.argument<String>("id")
                        val text = call.argument<String>("text")
                        result.success(
                            id != null && text != null &&
                                NotificationForwardingStore.reply(this, id, text)
                        )
                    }
                    "dismiss" -> {
                        val id = call.argument<String>("id")
                        result.success(
                            id != null &&
                                NotificationForwardingStore.dismiss(this, id)
                        )
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error(
                    "notification_forwarding_failed",
                    error.message ?: "Notification forwarding request failed.",
                    null
                )
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zephlink/file_picker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> {
                        if (pendingFilePickerResult != null ||
                            pendingFolderPickerResult != null
                        ) {
                            result.error(
                                "picker_busy",
                                "A file selection is already open.",
                                null
                            )
                        } else {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            try {
                                pendingFilePickerResult = result
                                startActivityForResult(intent, FILE_PICKER_REQUEST)
                            } catch (error: Exception) {
                                pendingFilePickerResult = null
                                result.error(
                                    "picker_unavailable",
                                    error.message ?: "Android could not open file selection.",
                                    null
                                )
                            }
                        }
                    }
                    "pickFolder" -> {
                        if (pendingFilePickerResult != null ||
                            pendingFolderPickerResult != null
                        ) {
                            result.error(
                                "picker_busy",
                                "A file selection is already open.",
                                null
                            )
                        } else {
                            try {
                                pendingFolderPickerResult = result
                                startActivityForResult(
                                    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                                    FOLDER_PICKER_REQUEST
                                )
                            } catch (error: Exception) {
                                pendingFolderPickerResult = null
                                result.error(
                                    "picker_unavailable",
                                    error.message ?: "Android could not open folder selection.",
                                    null
                                )
                            }
                        }
                    }
                    "deleteTemporaryFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("invalid_path", "Missing file path.", null)
                        } else {
                            try {
                                val outgoingDir = File(cacheDir, "zephlink_outgoing")
                                    .canonicalFile
                                val candidate = File(path).canonicalFile
                                val prefix = outgoingDir.path + File.separator
                                if (candidate.isFile && candidate.path.startsWith(prefix)) {
                                    candidate.delete()
                                    var parent = candidate.parentFile
                                    while (parent != null &&
                                        parent != outgoingDir &&
                                        parent.delete()
                                    ) {
                                        parent = parent.parentFile
                                    }
                                }
                                result.success(null)
                            } catch (error: Exception) {
                                result.error(
                                    "cleanup_failed",
                                    error.message ?: "Could not clean up the selected file.",
                                    null
                                )
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "zephlink/received_files")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "publish" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("Missing received-file path")
                            val name = call.argument<String>("name")
                                ?: throw IllegalArgumentException("Missing received-file name")
                            runReceivedFilesTask(result) {
                                publishReceivedFile(File(path), name)
                            }
                        }
                        "list" -> runReceivedFilesTask(result) { listReceivedFiles() }
                        "thumbnail" -> {
                            val uri = call.argument<String>("uri")
                                ?: throw IllegalArgumentException("Missing received-file URI")
                            runReceivedFilesTask(result) { createThumbnail(Uri.parse(uri)) }
                        }
                        "openFolder" -> {
                            openReceivedFolder()
                            result.success(true)
                        }
                        "openFile" -> {
                            val uri = call.argument<String>("uri")
                                ?: throw IllegalArgumentException("Missing received-file URI")
                            openReceivedFile(Uri.parse(uri))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error(
                        "received_files",
                        error.message ?: "Could not access received files",
                        null
                    )
                }
            }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (ScreenBridge.handleActivityResult(this, requestCode, resultCode, data)) return
        if (requestCode == FOLDER_PICKER_REQUEST) {
            val result = pendingFolderPickerResult ?: return
            pendingFolderPickerResult = null
            val treeUri = if (resultCode == RESULT_OK) data?.data else null
            if (treeUri == null) {
                result.success(emptyList<Map<String, Any>>())
                return
            }
            Thread {
                try {
                    val files = copyFolderToCache(treeUri)
                    runOnUiThread { result.success(files) }
                } catch (error: Exception) {
                    runOnUiThread {
                        result.error(
                            "folder_copy_failed",
                            error.message ?: "Could not read the selected folder.",
                            null
                        )
                    }
                }
            }.start()
            return
        }
        if (requestCode != FILE_PICKER_REQUEST) return
        val result = pendingFilePickerResult ?: return
        pendingFilePickerResult = null
        if (resultCode != RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }

        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let(uris::add)
            }
        } else {
            data.data?.let(uris::add)
        }
        Thread {
            try {
                val files = copySelectedFiles(uris)
                runOnUiThread { result.success(files) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "file_copy_failed",
                        error.message ?: "Could not read the selected file.",
                        null
                    )
                }
            }
        }.start()
    }

    private fun copySelectedFiles(uris: List<Uri>): List<Map<String, Any>> {
        val directory = File(cacheDir, "zephlink_outgoing")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not prepare files for sending.")
        }
        val copied = mutableListOf<File>()
        try {
            val entries = uris.map { uri ->
                val name = selectedDisplayName(uri)
                val file = uniqueFile(directory, name)
                val input = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("Android could not read $name.")
                input.use { source ->
                    file.outputStream().buffered().use { destination ->
                        source.copyTo(destination, 64 * 1024)
                    }
                }
                copied.add(file)
                mapOf(
                    "path" to file.absolutePath,
                    "name" to name,
                    "size" to file.length()
                )
            }
            return entries
        } catch (error: Exception) {
            copied.forEach { it.delete() }
            throw error
        }
    }

    private fun copyFolderToCache(treeUri: Uri): List<Map<String, Any>> {
        val treeId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootName = safeFileName(
            documentDisplayName(
                DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId)
            ) ?: "Shared folder"
        )
        val stagingRoot = File(
            File(cacheDir, "zephlink_outgoing"),
            "folder-${UUID.randomUUID()}"
        )
        if (!stagingRoot.mkdirs()) {
            throw IllegalStateException("Could not prepare the selected folder.")
        }

        val entries = mutableListOf<Map<String, Any>>()
        val visited = mutableSetOf<String>()
        try {
            fun copyChildren(parentId: String, relativeParent: String, depth: Int) {
                if (depth > 32) {
                    throw IllegalStateException("The selected folder is nested too deeply.")
                }
                if (!visited.add(parentId)) {
                    throw IllegalStateException("The selected folder contains a directory loop.")
                }
                val childrenUri =
                    DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
                val projection = arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                )
                contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                    val idColumn = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID
                    )
                    val nameColumn = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME
                    )
                    val mimeColumn = cursor.getColumnIndexOrThrow(
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    )
                    while (cursor.moveToNext()) {
                        if (entries.size >= 10000) {
                            throw IllegalStateException(
                                "The selected folder contains too many files (limit 10,000)."
                            )
                        }
                        val documentId = cursor.getString(idColumn)
                        val name = safeFileName(cursor.getString(nameColumn) ?: "file")
                        val relativePath = if (relativeParent.isEmpty()) {
                            "$rootName/$name"
                        } else {
                            "$relativeParent/$name"
                        }
                        if (relativePath.length > 1024) {
                            throw IllegalStateException(
                                "A path in the selected folder is too long."
                            )
                        }
                        if (cursor.getString(mimeColumn) ==
                            DocumentsContract.Document.MIME_TYPE_DIR
                        ) {
                            copyChildren(documentId, relativePath, depth + 1)
                        } else {
                            val segments = relativePath.split('/')
                            val destinationDirectory = File(
                                stagingRoot,
                                segments.dropLast(1).joinToString(File.separator)
                            )
                            if (!destinationDirectory.exists() &&
                                !destinationDirectory.mkdirs()
                            ) {
                                throw IllegalStateException(
                                    "Could not prepare a folder for ${segments.last()}."
                                )
                            }
                            val destination = uniqueFile(
                                destinationDirectory,
                                segments.last()
                            )
                            val documentUri =
                                DocumentsContract.buildDocumentUriUsingTree(
                                    treeUri,
                                    documentId
                                )
                            val input = contentResolver.openInputStream(documentUri)
                                ?: throw IllegalStateException(
                                    "Android could not read ${segments.last()}."
                                )
                            input.use { source ->
                                destination.outputStream().buffered().use { output ->
                                    source.copyTo(output, 64 * 1024)
                                }
                            }
                            val actualRelativePath = segments.dropLast(1)
                                .plus(destination.name)
                                .joinToString("/")
                            entries.add(
                                mapOf(
                                    "path" to destination.absolutePath,
                                    "name" to destination.name,
                                    "relativePath" to actualRelativePath,
                                    "size" to destination.length()
                                )
                            )
                        }
                    }
                } ?: throw IllegalStateException(
                    "Android could not read the selected folder."
                )
            }
            copyChildren(treeId, "", 0)
            if (entries.isEmpty()) stagingRoot.deleteRecursively()
            return entries
        } catch (error: Exception) {
            stagingRoot.deleteRecursively()
            throw error
        }
    }

    private fun documentDisplayName(uri: Uri): String? {
        contentResolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            val column = cursor.getColumnIndex(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME
            )
            if (column >= 0 && cursor.moveToFirst()) return cursor.getString(column)
        }
        return null
    }

    private fun selectedDisplayName(uri: Uri): String {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (nameColumn >= 0 && cursor.moveToFirst()) {
                cursor.getString(nameColumn)?.let { return safeFileName(it) }
            }
        }
        return "shared-file"
    }

    private fun safeFileName(name: String): String {
        val safe = name.replace(Regex("[<>:\"/\\\\|?*\\u0000-\\u001f]"), "_")
            .trim()
            .trimEnd('.')
        if (safe.isEmpty() || safe == "." || safe == "..") return "shared-file"
        return safe.takeLast(120)
    }

    private fun runReceivedFilesTask(result: MethodChannel.Result, task: () -> Any?) {
        Thread {
            try {
                val value = task()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "received_files",
                        error.message ?: "Could not access received files",
                        null
                    )
                }
            }
        }.start()
    }

    private fun publishReceivedFile(source: File, requestedName: String): Map<String, Any> {
        if (!source.isFile) throw IllegalArgumentException("Received file no longer exists")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val downloads = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val directory = File(downloads, "Zephlink")
            if (!directory.exists() && !directory.mkdirs()) {
                throw IllegalStateException("Could not create the received-files folder")
            }
            val destination = uniqueFile(directory, requestedName)
            source.copyTo(destination)
            return mapOf(
                "name" to destination.name,
                "uri" to Uri.fromFile(destination).toString(),
                "size" to destination.length()
            )
        }

        val resolver = contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/Zephlink/"
        val name = uniqueMediaStoreName(collection, relativePath, requestedName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            val extension = name.substringAfterLast('.', "")
            val mimeType = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(extension.lowercase())
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType ?: "application/octet-stream")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Android could not create the received file")
        try {
            val output = resolver.openOutputStream(uri, "w")
                ?: throw IllegalStateException("Android could not open the received file")
            FileInputStream(source).use { input ->
                output.use { input.copyTo(it) }
            }
            val completed = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, completed, null, null)
            return mapOf(
                "name" to name,
                "uri" to uri.toString(),
                "size" to source.length()
            )
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun uniqueMediaStoreName(
        collection: Uri,
        relativePath: String,
        requestedName: String
    ): String {
        val dot = requestedName.lastIndexOf('.')
        val base = if (dot > 0) requestedName.substring(0, dot) else requestedName
        val extension = if (dot > 0) requestedName.substring(dot) else ""
        var index = 0
        while (true) {
            val candidate = if (index == 0) requestedName else "$base ($index)$extension"
            val exists = contentResolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                    "${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                arrayOf(candidate, relativePath),
                null
            )?.use { it.moveToFirst() } ?: false
            if (!exists) return candidate
            index++
        }
    }

    private fun listReceivedFiles(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val downloads = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
            val directory = File(downloads, "Zephlink")
            return directory.listFiles()
                ?.filter { it.isFile }
                ?.sortedByDescending { it.lastModified() }
                ?.map {
                    mapOf(
                        "name" to it.name,
                        "uri" to Uri.fromFile(it).toString(),
                        "size" to it.length()
                    )
                } ?: emptyList()
        }

        val result = mutableListOf<Map<String, Any>>()
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns._ID
        )
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND " +
            "${MediaStore.MediaColumns.IS_PENDING} = 0"
        contentResolver.query(
            collection,
            projection,
            selection,
            arrayOf("${Environment.DIRECTORY_DOWNLOADS}/Zephlink/"),
            "${MediaStore.MediaColumns.DATE_ADDED} DESC"
        )?.use { cursor: Cursor ->
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            while (cursor.moveToNext()) {
                val uri = Uri.withAppendedPath(collection, cursor.getString(idColumn))
                result.add(
                    mapOf(
                        "name" to cursor.getString(nameColumn),
                        "uri" to uri.toString(),
                        "size" to cursor.getLong(sizeColumn)
                    )
                )
            }
        }
        return result
    }

    private fun createThumbnail(uri: Uri): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = 1
            while (bounds.outWidth / inSampleSize > 256 ||
                bounds.outHeight / inSampleSize > 256
            ) {
                inSampleSize *= 2
            }
        }
        val bitmap = contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: return null
        try {
            return ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 75, output)
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun openReceivedFolder() {
        val documentUri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:Download/Zephlink"
        )
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(documentUri, "vnd.android.document/directory")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (packageManager.resolveActivity(viewIntent, 0) != null) {
            startActivity(Intent.createChooser(viewIntent, "Open received files"))
            return
        }
        val treeIntent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            treeIntent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, documentUri)
        }
        startActivity(treeIntent)
    }

    private fun openReceivedFile(uri: Uri) {
        val mimeType = contentResolver.getType(uri) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "Open received file"))
    }

    private fun uniqueFile(directory: File, name: String): File {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        var index = 0
        while (true) {
            val candidate = if (index == 0) name else "$base ($index)$extension"
            val file = File(directory, candidate)
            if (!file.exists()) return file
            index++
        }
    }

    companion object {
        private const val FILE_PICKER_REQUEST = 4713
        private const val FOLDER_PICKER_REQUEST = 4714
    }
}
