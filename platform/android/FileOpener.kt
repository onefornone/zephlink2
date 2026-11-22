package app.zephlink.zephlink

import android.app.Activity
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import android.widget.Toast

/**
 * Opens received files and the received-files folder.
 *
 * - Folder: finds every file manager on the phone and lets the person pick one.
 * - Apps (.apk): installs through Android's package installer, and sends the
 *   person to the "install unknown apps" switch first when it is off.
 * - Everything else: opens with the app Android picks for that file type.
 */
object FileOpener {
    private const val APK_MIME = "application/vnd.android.package-archive"
    private var receiverReady = false

    private val knownManagers = listOf(
        "com.google.android.apps.nbu.files",
        "com.google.android.documentsui",
        "com.android.documentsui",
        "com.sec.android.app.myfiles",
        "com.mi.android.globalFileexplorer",
        "com.alphainventor.filemanager",
        "ru.zdevs.zarchiver",
        "com.lonelycatgames.Xplore",
        "com.mixplorer",
        "com.estrongs.android.pop",
        "pl.solidexplorer2",
        "nextapp.fx",
        "com.ghisler.android.TotalCommander",
        "com.cxinventor.file.explorer",
        "com.speedsoftware.explorer",
        "me.zhanghai.android.files",
        "com.amaze.filemanager",
    )

    // ---------------------------------------------------------------- folder

    private class Option(val label: String, val intent: Intent, val hint: Boolean)

    /** Returns null when something opened, otherwise a short reason. */
    fun openFolder(activity: Activity): String? {
        val pm = activity.packageManager
        val documentUri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:Download/Zephlink"
        )
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(documentUri, "vnd.android.document/directory")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val options = LinkedHashMap<String, Option>()

        // Apps that can open the folder itself.
        try {
            for (info in pm.queryIntentActivities(view, 0)) {
                val pkg = info.activityInfo.packageName
                if (pkg == activity.packageName || options.containsKey(pkg)) continue
                val intent = Intent(view).setClassName(pkg, info.activityInfo.name)
                options[pkg] = Option(info.loadLabel(pm).toString(), intent, false)
            }
        } catch (error: Exception) {
            // Keep going with the other ways below.
        }

        // Known file managers and anything that looks like one.
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val words = Regex("file|explorer|archiver|document|manager")
        try {
            for (info in pm.queryIntentActivities(launcher, 0)) {
                val pkg = info.activityInfo.packageName
                if (pkg == activity.packageName || options.containsKey(pkg)) continue
                val label = info.loadLabel(pm).toString()
                val lower = label.lowercase()
                val looksRight = knownManagers.contains(pkg) ||
                    words.containsMatchIn(lower) || words.containsMatchIn(pkg.lowercase())
                val unrelated = lower.contains("filter") || lower.contains("profile") ||
                    lower.contains("account") || lower.contains("package") ||
                    lower.contains("manager") && !lower.contains("file")
                if (!looksRight || unrelated) continue
                val intent = pm.getLaunchIntentForPackage(pkg) ?: continue
                options[pkg] = Option(label, intent, true)
            }
        } catch (error: Exception) {
            // Keep going.
        }

        val list = options.values.toList()
        if (list.size == 1) {
            if (start(activity, list[0])) return null
        } else if (list.size > 1) {
            AlertDialog.Builder(activity)
                .setTitle("Open Downloads/Zephlink with")
                .setItems(list.map { it.label }.toTypedArray()) { _, index ->
                    if (!start(activity, list[index])) {
                        Toast.makeText(activity, "Could not open that app.", Toast.LENGTH_LONG).show()
                    }
                }
                .setNegativeButton("Cancel", null)
                .show()
            return null
        }

        // Last resorts: Android's own Downloads screen, then a folder picker.
        val downloads = Intent("android.intent.action.VIEW_DOWNLOADS")
        try {
            activity.startActivity(downloads)
            return null
        } catch (error: Exception) {
            // Try the picker.
        }
        return try {
            val tree = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                tree.putExtra(DocumentsContract.EXTRA_INITIAL_URI, documentUri)
            }
            activity.startActivity(tree)
            null
        } catch (error: Exception) {
            "No file manager was found on this phone. Install one, for example Files by Google or ZArchiver."
        }
    }

    private fun start(activity: Activity, option: Option): Boolean {
        return try {
            activity.startActivity(option.intent)
            if (option.hint) {
                Toast.makeText(
                    activity,
                    "Open Downloads, then the Zephlink folder.",
                    Toast.LENGTH_LONG
                ).show()
            }
            true
        } catch (error: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------ file

    private fun displayName(activity: Activity, uri: Uri): String {
        try {
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val name = cursor.getString(0)
                        if (!name.isNullOrEmpty()) return name
                    }
                }
        } catch (error: Exception) {
            // Fall back to the address.
        }
        return uri.lastPathSegment ?: ""
    }

    private fun mimeFor(activity: Activity, uri: Uri, name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        if (extension == "apk") return APK_MIME
        val fromType = activity.contentResolver.getType(uri)
        if (!fromType.isNullOrEmpty() && fromType != "application/octet-stream") return fromType
        val guessed = if (extension.isEmpty()) null
        else MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        return guessed ?: fromType ?: "*/*"
    }

    /**
     * Calls [done] on the main thread with null when it worked, or a short
     * reason when it did not.
     */
    fun openFile(activity: Activity, uri: Uri, done: (String?) -> Unit) {
        val name = displayName(activity, uri)
        val mime = mimeFor(activity, uri, name)
        if (mime != APK_MIME) {
            try {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                activity.startActivity(Intent.createChooser(intent, "Open received file"))
                done(null)
            } catch (error: Exception) {
                done("No app on this phone can open this file.")
            }
            return
        }
        installApk(activity, uri, done)
    }

    private fun installApk(activity: Activity, uri: Uri, done: (String?) -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            try {
                val settings = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + activity.packageName)
                )
                activity.startActivity(settings)
                done("Turn on \"Allow from this source\" for Zephlink, go back, then press install again.")
            } catch (error: Exception) {
                done("Allow Zephlink to install apps in Android Settings, Apps, Special access, Install unknown apps.")
            }
            return
        }
        ensureReceiver(activity.applicationContext)
        Thread {
            var reason: String? = null
            try {
                commitSession(activity, uri)
            } catch (error: Exception) {
                reason = "Could not start the install: " + (error.message ?: "unknown error")
            }
            activity.runOnUiThread { done(reason) }
        }.start()
    }

    private fun commitSession(activity: Activity, uri: Uri) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        val id = installer.createSession(params)
        val session = installer.openSession(id)
        try {
            val input = activity.contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("The file could not be read")
            input.use { stream ->
                val out = session.openWrite("zephlink.apk", 0, -1)
                out.use { sink ->
                    stream.copyTo(sink)
                    session.fsync(sink)
                }
            }
            val intent = Intent(activity.packageName + ".APK_INSTALL_STATUS")
                .setPackage(activity.packageName)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getBroadcast(activity.applicationContext, id, intent, flags)
            session.commit(pending.intentSender)
        } catch (error: Exception) {
            try {
                session.abandon()
            } catch (ignored: Exception) {
            }
            throw error
        } finally {
            session.close()
        }
    }

    @Suppress("DEPRECATION")
    private fun ensureReceiver(context: Context) {
        if (receiverReady) return
        receiverReady = true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)
                when (status) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        if (confirm != null) {
                            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try {
                                ctx.startActivity(confirm)
                            } catch (error: Exception) {
                                Toast.makeText(
                                    ctx,
                                    "Open Zephlink and press install again.",
                                    Toast.LENGTH_LONG
                                ).show()
                            }
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS -> Unit
                    else -> {
                        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                        Toast.makeText(
                            ctx,
                            "The app was not installed" +
                                (if (message.isNullOrEmpty()) "." else ": $message"),
                            Toast.LENGTH_LONG
                        ).show()
                    }
                }
            }
        }
        val filter = IntentFilter(context.packageName + ".APK_INSTALL_STATUS")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }
}
