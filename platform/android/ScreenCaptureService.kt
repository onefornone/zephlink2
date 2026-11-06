package app.zephlink.zephlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.ByteArrayOutputStream

/**
 * Takes pictures of the phone screen (after Android's own permission box) and
 * hands them to the app as small JPEG files. It shows a notification while it
 * runs, as Android requires.
 */
class ScreenCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var worker: HandlerThread? = null
    private var lastFrameAt = 0L
    private var frameGap = 100L
    private var quality = 65
    private var stopping = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        showNotification()
        val resultCode = intent.getIntExtra("resultCode", 0)
        val data = readCaptureIntent(intent)
        if (data == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val maxSide = intent.getIntExtra("maxSide", 1080).coerceIn(320, 2560)
        quality = intent.getIntExtra("quality", 65).coerceIn(10, 95)
        val fps = intent.getIntExtra("fps", 10).coerceIn(1, 30)
        frameGap = 1000L / fps
        try {
            startCapture(resultCode, data, maxSide)
        } catch (error: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startCapture(resultCode: Int, data: Intent, maxSide: Int) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = manager.getMediaProjection(resultCode, data)
        projection = mp

        val thread = HandlerThread("zephlink-capture")
        thread.start()
        worker = thread
        val handler = Handler(thread.looper)

        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }, handler)

        val metrics = DisplayMetrics()
        val windows = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        readRealMetrics(windows, metrics)
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val scale = Math.min(1.0, maxSide.toDouble() / Math.max(width, height).toDouble())
        val outWidth = Math.max(2, (width * scale).toInt() and 1.inv())
        val outHeight = Math.max(2, (height * scale).toInt() and 1.inv())

        val images = ImageReader.newInstance(outWidth, outHeight, PixelFormat.RGBA_8888, 2)
        reader = images
        display = mp.createVirtualDisplay(
            "zephlink-screen",
            outWidth,
            outHeight,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            images.surface,
            null,
            handler
        )
        images.setOnImageAvailableListener({ source -> onImage(source) }, handler)
    }

    private fun onImage(source: ImageReader) {
        var found: android.media.Image? = null
        try {
            found = source.acquireLatestImage()
        } catch (error: Exception) {
            found = null
        }
        val image = found ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            if (now - lastFrameAt < frameGap) return
            lastFrameAt = now

            val plane = image.planes[0]
            val pixelStride = plane.pixelStride
            val rowPadding = plane.rowStride - pixelStride * image.width
            val padded = Bitmap.createBitmap(
                image.width + rowPadding / pixelStride,
                image.height,
                Bitmap.Config.ARGB_8888
            )
            padded.copyPixelsFromBuffer(plane.buffer)
            val picture = if (rowPadding == 0) {
                padded
            } else {
                Bitmap.createBitmap(padded, 0, 0, image.width, image.height)
            }
            val out = ByteArrayOutputStream(64 * 1024)
            picture.compress(Bitmap.CompressFormat.JPEG, quality, out)
            if (picture !== padded) picture.recycle()
            padded.recycle()
            ScreenBridge.emitFrame(out.toByteArray())
        } catch (error: Exception) {
            // Skip this picture.
        } finally {
            image.close()
        }
    }

    private fun showNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Zephlink screen sharing",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shown while your screen is shared"
            manager.createNotificationChannel(channel)
        }
        val builder = createBuilder()
        builder
            .setContentTitle("Zephlink is sharing your screen")
            .setContentText("Open Zephlink to stop sharing")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    1,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        }
        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun createBuilder(): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
    }

    @Suppress("DEPRECATION")
    private fun readCaptureIntent(intent: Intent): Intent? {
        return intent.getParcelableExtra<Intent>("data")
    }

    @Suppress("DEPRECATION")
    private fun readRealMetrics(windows: WindowManager, metrics: DisplayMetrics) {
        windows.defaultDisplay.getRealMetrics(metrics)
    }

    override fun onDestroy() {
        if (!stopping) {
            stopping = true
            try {
                reader?.setOnImageAvailableListener(null, null)
                display?.release()
                reader?.close()
                projection?.stop()
                worker?.quitSafely()
            } catch (error: Exception) {
                // Already released.
            }
            display = null
            reader = null
            projection = null
            worker = null
            ScreenBridge.emitStopped()
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "zephlink_screen"
        private const val NOTIFICATION_ID = 4712
    }
}
