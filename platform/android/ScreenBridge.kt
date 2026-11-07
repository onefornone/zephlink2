package app.zephlink.zephlink

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Connects the Flutter app to screen sharing and remote control:
 *  - "zephlink/screen": start and stop sharing the screen
 *  - "zephlink/screen/frames": the pictures (and a "stopped" note)
 *  - "zephlink/control": the remote-control (accessibility) service
 */
object ScreenBridge {
    private const val REQUEST_CAPTURE = 4801

    private var pendingResult: MethodChannel.Result? = null
    private var pendingMaxSide = 1080
    private var pendingQuality = 65
    private var pendingFps = 10
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(host: Activity, messenger: BinaryMessenger) {
        ToolsBridge.register(host, messenger)
        MethodChannel(messenger, "zephlink/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (pendingResult != null) {
                        result.error("busy", "Already waiting for permission.", null)
                    } else {
                        pendingMaxSide = number(call, "maxSide")?.toInt() ?: 1080
                        pendingQuality = number(call, "quality")?.toInt() ?: 65
                        pendingFps = number(call, "fps")?.toInt() ?: 10
                        val manager =
                            host.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        pendingResult = result
                        try {
                            startCaptureDialog(host, manager)
                        } catch (error: Exception) {
                            pendingResult = null
                            result.error("failed", "Could not ask for screen permission.", null)
                        }
                    }
                }
                "stop" -> {
                    host.stopService(Intent(host, ScreenCaptureService::class.java))
                    result.success(true)
                }
                "codec" -> {
                    val service = ScreenCaptureService.instance
                    val mode = call.argument<String>("mode") ?: "jpeg"
                    result.success(service?.setCodec(mode) ?: false)
                }
                "keyframe" -> {
                    ScreenCaptureService.instance?.requestKeyFrame()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "zephlink/screen/frames").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            }
        )

        MethodChannel(messenger, "zephlink/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "enabled" -> result.success(RemoteControlService.instance != null)
                "openSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        host.startActivity(intent)
                        result.success(true)
                    } catch (error: Exception) {
                        result.success(false)
                    }
                }
                "apply" -> result.success(applyInput(host, call))
                "overlayAllowed" -> result.success(QuickActions.canDrawOverApps(host))
                "openOverlaySettings" -> result.success(QuickActions.openOverlaySettings(host))
                "quick" -> result.success(QuickActions.run(host, call.argument<String>("a") ?: "", call.argument<String>("s")))
                "apps" -> result.success(QuickActions.apps(host))
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun startCaptureDialog(host: Activity, manager: MediaProjectionManager) {
        host.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE)
    }

    /** Called from MainActivity. Returns true when the result was ours. */
    fun handleActivityResult(host: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CAPTURE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(false)
            return true
        }
        val intent = Intent(host, ScreenCaptureService::class.java)
        intent.putExtra("resultCode", resultCode)
        intent.putExtra("data", data)
        intent.putExtra("maxSide", pendingMaxSide)
        intent.putExtra("quality", pendingQuality)
        intent.putExtra("fps", pendingFps)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                host.startForegroundService(intent)
            } else {
                host.startService(intent)
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("failed", error.message ?: "Could not start screen sharing.", null)
        }
        return true
    }

    /** Sends one picture to the app. Safe to call from any thread. */
    fun emitFrame(bytes: ByteArray) {
        main.post { sink?.success(bytes) }
    }

    /** Sends a short note (such as "h264-failed") to the app. */
    fun emitText(text: String) {
        main.post { sink?.success(text) }
    }

    /** Tells the app that sharing ended (for example from the Android chip). */
    fun emitStopped() {
        main.post { sink?.success("stopped") }
    }

    private fun number(call: MethodCall, key: String): Double? {
        val value = call.argument<Any>(key)
        return (value as? Number)?.toDouble()
    }

    private fun applyInput(host: Activity, call: MethodCall): Boolean {
        val service = RemoteControlService.instance ?: return false
        val metrics = DisplayMetrics()
        val windows = host.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        readRealMetrics(windows, metrics)
        val width = metrics.widthPixels.toFloat()
        val height = metrics.heightPixels.toFloat()
        fun unit(key: String): Float {
            val v = number(call, key)?.toFloat() ?: 0f
            return v.coerceIn(0f, 1f)
        }
        return when (call.argument<String>("k")) {
            "tap" -> service.swipe(unit("x") * width, unit("y") * height, unit("x") * width, unit("y") * height, 60L)
            "long" -> service.swipe(unit("x") * width, unit("y") * height, unit("x") * width, unit("y") * height, 700L)
            "swipe" -> {
                val ms = (number(call, "ms")?.toLong() ?: 300L).coerceIn(80L, 1500L)
                service.swipe(
                    unit("x1") * width, unit("y1") * height,
                    unit("x2") * width, unit("y2") * height, ms
                )
            }
            "nav" -> service.navigate(call.argument<String>("a") ?: "")
            "text" -> {
                val text = call.argument<String>("s") ?: ""
                service.typeText(if (text.length > 500) text.substring(0, 500) else text)
            }
            else -> false
        }
    }

    @Suppress("DEPRECATION")
    private fun readRealMetrics(windows: WindowManager, metrics: DisplayMetrics) {
        windows.defaultDisplay.getRealMetrics(metrics)
    }
}
