package app.zephlink.zephlink

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * "zephlink/tools": things the PC can ask this phone to do.
 *  - ring loudly (even on silent) and stop again
 *  - report the battery level
 *  - tell whether Zephlink may read all files, and open that setting
 *  - list the storage roots (internal storage, SD card)
 */
object ToolsBridge {
    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var savedVolume = -1
    private var stopTask: Runnable? = null

    fun register(host: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "zephlink/tools").setMethodCallHandler { call, result ->
            when (call.method) {
                "ring" -> result.success(ring(host, call.argument<Int>("seconds") ?: 60))
                "stopRing" -> {
                    stopRing(host)
                    result.success(true)
                }
                "ringing" -> result.success(player != null)
                "battery" -> result.success(battery(host))
                "filesAllowed" -> result.success(filesAllowed(host))
                "openFilesAccess" -> result.success(openFilesAccess(host))
                "roots" -> result.success(roots())
                else -> result.notImplemented()
            }
        }
    }

    private fun ring(context: Context, seconds: Int): Boolean {
        stopRing(context)
        return try {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            try {
                savedVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
                audio.setStreamVolume(
                    AudioManager.STREAM_ALARM,
                    audio.getStreamMaxVolume(AudioManager.STREAM_ALARM),
                    0
                )
            } catch (error: Exception) {
                // Some phones refuse to change the volume. Ring anyway.
            }
            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: return false
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            mp.setDataSource(context, uri)
            mp.isLooping = true
            mp.prepare()
            mp.start()
            player = mp
            val task = Runnable { stopRing(context) }
            stopTask = task
            main.postDelayed(task, seconds.coerceIn(5, 300) * 1000L)
            true
        } catch (error: Exception) {
            stopRing(context)
            false
        }
    }

    private fun stopRing(context: Context) {
        stopTask?.let { main.removeCallbacks(it) }
        stopTask = null
        try {
            player?.stop()
        } catch (error: Exception) {
        }
        try {
            player?.release()
        } catch (error: Exception) {
        }
        player = null
        if (savedVolume >= 0) {
            try {
                val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audio.setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
            } catch (error: Exception) {
            }
            savedVolume = -1
        }
    }

    private fun battery(context: Context): Map<String, Any> {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf("pct" to percent, "charging" to charging)
    }

    private fun filesAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 30) return Environment.isExternalStorageManager()
        if (Build.VERSION.SDK_INT >= 23) {
            return context.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    private fun openFilesAccess(context: Context): Boolean {
        val uri = Uri.parse("package:" + context.packageName)
        val attempts = ArrayList<Intent>()
        if (Build.VERSION.SDK_INT >= 30) {
            attempts.add(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, uri))
            attempts.add(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
        attempts.add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri))
        for (intent in attempts) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                return true
            } catch (error: Exception) {
            }
        }
        return false
    }

    @Suppress("DEPRECATION")
    private fun roots(): List<Map<String, String>> {
        val list = ArrayList<Map<String, String>>()
        val primary = Environment.getExternalStorageDirectory()
        list.add(mapOf("name" to "Internal storage", "path" to primary.absolutePath))
        val volumes = File("/storage").listFiles()
        if (volumes != null) {
            for (volume in volumes) {
                if (!volume.isDirectory) continue
                if (volume.name == "emulated" || volume.name == "self") continue
                if (!volume.canRead()) continue
                list.add(mapOf("name" to "SD card or USB (" + volume.name + ")", "path" to volume.absolutePath))
            }
        }
        return list
    }
}
