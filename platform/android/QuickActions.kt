package app.zephlink.zephlink

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings

/**
 * Short one-tap actions a paired PC may run on this phone, after the phone's
 * owner allowed control. Each call returns null when it worked, or a short
 * reason when it did not.
 */
object QuickActions {
    private var torchOn = false

    fun run(host: Activity, action: String, argument: String?): String? {
        val service = RemoteControlService.instance
        return when (action) {
            "lock", "power", "screenshot", "quicksettings", "notifications",
            "recents", "home", "back" -> {
                if (service == null) {
                    "Turn on Zephlink remote control in Android Accessibility settings."
                } else if (service.navigate(action)) {
                    null
                } else {
                    "This phone does not support that action."
                }
            }
            "files" -> openFiles(host)
            "settings" -> launch(host, Intent(Settings.ACTION_SETTINGS)) ?: backgroundHint(host)
            "camera" -> launch(host, Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA)) ?: backgroundHint(host)
            "url" -> openUrl(host, argument)
            "app" -> openApp(host, argument)
            "volup" -> volume(host, AudioManager.ADJUST_RAISE)
            "voldown" -> volume(host, AudioManager.ADJUST_LOWER)
            "mute" -> volume(host, AudioManager.ADJUST_TOGGLE_MUTE)
            "torch" -> torch(host)
            else -> "Unknown action."
        }
    }

    private fun starter(host: Activity): Context {
        return RemoteControlService.instance ?: host
    }

    private fun launch(host: Activity, intent: Intent): String? {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            starter(host).startActivity(intent)
            null
        } catch (error: Exception) {
            "Android would not open it right now. Unlock the phone and try again."
        }
    }

    private val knownFileManagers = listOf(
        "com.google.android.documentsui",
        "com.android.documentsui",
        "com.google.android.apps.nbu.files",
        "com.sec.android.app.myfiles",
        "com.mi.android.globalFileexplorer",
        "com.android.fileexplorer",
        "com.coloros.filemanager",
        "com.oppo.filemanager",
        "com.vivo.filemanager",
        "com.android.filemanager",
        "com.hihonor.filemanager",
        "com.huawei.filemanager",
        "ru.zdevs.zarchiver",
        "ru.zdevs.zarchiver.pro",
        "pl.solidexplorer2",
        "com.nextapp.fx",
        "com.cxinventor.file.explorer",
        "me.zhanghai.android.files",
        "com.amaze.filemanager",
        "com.mixplorer",
        "com.mixplorer.silver",
        "com.lonelycatgames.Xplore",
        "com.ghisler.android.TotalCommander",
        "com.alphainventor.filemanager",
        "com.estrongs.android.pop",
        "org.openintents.filemanager"
    )

    /**
     * Opens any file manager it can find: well known ones first, then any
     * installed app whose name looks like a file manager (ZArchiver, Files,
     * Explorer, ...), then Android's own Downloads and storage screens.
     */
    @Suppress("DEPRECATION")
    private fun openFiles(host: Activity): String? {
        val manager = host.packageManager
        val tried = HashSet<String>()

        for (pkg in knownFileManagers) {
            val intent = manager.getLaunchIntentForPackage(pkg) ?: continue
            tried.add(pkg)
            if (launch(host, intent) == null) return backgroundHint(host)
        }

        val launcher = Intent(Intent.ACTION_MAIN)
        launcher.addCategory(Intent.CATEGORY_LAUNCHER)
        val words = Regex("file|explorer|archiver|document|storage|manager")
        val found = try {
            manager.queryIntentActivities(launcher, 0)
        } catch (error: Exception) {
            emptyList<android.content.pm.ResolveInfo>()
        }
        for (info in found) {
            val pkg = info.activityInfo.packageName
            if (pkg == host.packageName || tried.contains(pkg)) continue
            val label = info.loadLabel(manager).toString().lowercase()
            val looksRight = words.containsMatchIn(label) || words.containsMatchIn(pkg.lowercase())
            val unrelated = label.contains("filter") || label.contains("profile") ||
                label.contains("account") || label.contains("package")
            if (!looksRight || unrelated) continue
            val intent = manager.getLaunchIntentForPackage(pkg) ?: continue
            tried.add(pkg)
            if (launch(host, intent) == null) return backgroundHint(host)
        }

        val roots = Intent(Intent.ACTION_VIEW)
        roots.setDataAndType(
            Uri.parse("content://com.android.externalstorage.documents/root/primary"),
            "vnd.android.document/root"
        )
        val last = listOf(
            Intent("android.intent.action.VIEW_DOWNLOADS"),
            roots,
            Intent.createChooser(
                Intent(Intent.ACTION_GET_CONTENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE),
                "Files"
            )
        )
        for (intent in last) {
            if (launch(host, intent) == null) return backgroundHint(host)
        }
        return "No file manager was found on this phone. Install one, for example Files by Google or ZArchiver."
    }

    /** Android sometimes blocks apps from opening screens while in the background. */
    private fun backgroundHint(host: Activity): String? {
        return try {
            val info = android.app.ActivityManager.RunningAppProcessInfo()
            android.app.ActivityManager.getMyMemoryState(info)
            val visible = info.importance <= android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            if (visible || canDrawOverApps(host)) {
                null
            } else {
                "Sent, but Android may block it while Zephlink is in the background. " +
                    "On the phone, open Zephlink, Screen tab, and allow \"Display over other apps\"."
            }
        } catch (error: Exception) {
            null
        }
    }

    fun canDrawOverApps(host: Activity): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(host)
        } else {
            true
        }
    }

    fun openOverlaySettings(host: Activity): Boolean {
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + host.packageName)
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            host.startActivity(intent)
            true
        } catch (error: Exception) {
            false
        }
    }

    private fun openUrl(host: Activity, argument: String?): String? {
        val text = argument?.trim() ?: return "No web address."
        if (text.length > 2000) return "That address is too long."
        val uri = try {
            Uri.parse(text)
        } catch (error: Exception) {
            return "That is not a web address."
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return "Only http and https addresses work."
        return launch(host, Intent(Intent.ACTION_VIEW, uri)) ?: backgroundHint(host)
    }

    private fun openApp(host: Activity, argument: String?): String? {
        val name = argument ?: return "No app chosen."
        val intent = host.packageManager.getLaunchIntentForPackage(name)
            ?: return "That app is not installed."
        return launch(host, intent) ?: backgroundHint(host)
    }

    private fun volume(host: Activity, direction: Int): String? {
        return try {
            val audio = host.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (direction == AudioManager.ADJUST_TOGGLE_MUTE && Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                return "This Android version cannot do that."
            }
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
            null
        } catch (error: Exception) {
            "Could not change the volume."
        }
    }

    private fun torch(host: Activity): String? {
        return try {
            val cameras = host.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            var chosen: String? = null
            for (id in cameras.cameraIdList) {
                val flash = cameras.getCameraCharacteristics(id).get(CameraCharacteristics.FLASH_INFO_AVAILABLE)
                if (flash == true) {
                    chosen = id
                    break
                }
            }
            if (chosen == null) return "This phone has no flashlight."
            torchOn = !torchOn
            cameras.setTorchMode(chosen, torchOn)
            null
        } catch (error: Exception) {
            torchOn = false
            "Could not use the flashlight."
        }
    }

    /** Apps with a launcher icon, sorted by name. */
    @Suppress("DEPRECATION")
    fun apps(host: Activity): List<Map<String, String>> {
        val manager = host.packageManager
        val query = Intent(Intent.ACTION_MAIN)
        query.addCategory(Intent.CATEGORY_LAUNCHER)
        val found = try {
            manager.queryIntentActivities(query, 0)
        } catch (error: Exception) {
            emptyList<android.content.pm.ResolveInfo>()
        }
        val list = ArrayList<Map<String, String>>()
        val seen = HashSet<String>()
        for (info in found) {
            val pkg = info.activityInfo.packageName
            if (pkg == host.packageName || !seen.add(pkg)) continue
            val label = info.loadLabel(manager).toString()
            list.add(mapOf("label" to label, "pkg" to pkg))
        }
        list.sortBy { it["label"]?.lowercase() ?: "" }
        return list.take(400)
    }
}
