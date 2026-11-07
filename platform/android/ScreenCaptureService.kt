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
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.Surface
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
    private var outWidth = 0
    private var outHeight = 0
    private var fps = 10
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var encoderThread: Thread? = null

    @Volatile
    private var encoding = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

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
        fps = intent.getIntExtra("fps", 10).coerceIn(1, 30)
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
        val mp: MediaProjection = manager.getMediaProjection(resultCode, data) ?: return
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
        // Multiples of 16 keep every phone's video encoder happy.
        outWidth = Math.max(16, (width * scale).toInt() and 15.inv())
        outHeight = Math.max(16, (height * scale).toInt() and 15.inv())

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

    /** Switches between small JPEG pictures ("jpeg") and H.264 video ("h264"). */
    @Synchronized
    fun setCodec(mode: String): Boolean {
        val screen = display ?: return false
        val pictures = reader ?: return false
        if (mode == "h264") {
            if (encoding) return true
            return try {
                startEncoder(screen)
                true
            } catch (error: Exception) {
                stopEncoder()
                try {
                    screen.surface = pictures.surface
                } catch (inner: Exception) {
                    // Keep going with whatever surface is attached.
                }
                false
            }
        }
        stopEncoder()
        try {
            screen.surface = pictures.surface
        } catch (error: Exception) {
            return false
        }
        return true
    }

    @Synchronized
    fun requestKeyFrame() {
        val codec = encoder ?: return
        if (!encoding) return
        try {
            val params = Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec.setParameters(params)
        } catch (error: Exception) {
            // Not available right now.
        }
    }

    private fun startEncoder(screen: VirtualDisplay) {
        val pixels = outWidth.toLong() * outHeight.toLong()
        val bitrate = (pixels * 30L / 4L).coerceIn(1_500_000L, 10_000_000L).toInt()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outWidth, outHeight)
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        try {
            format.setFloat("max-fps-to-encoder", Math.max(fps, 15).toFloat())
        } catch (error: Exception) {
            // Optional hint only.
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        encoderSurface = surface
        encoding = true
        screen.surface = surface
        val thread = Thread { drainEncoder(codec) }
        thread.name = "zephlink-encoder"
        encoderThread = thread
        thread.start()
    }

    private fun drainEncoder(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var config: ByteArray? = null
        try {
            while (encoding) {
                val index = codec.dequeueOutputBuffer(info, 100_000L)
                if (index < 0) continue
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buffer.get(bytes)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        config = bytes
                    } else {
                        val key = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                        val head = config
                        val payload = if (key && head != null) head + bytes else bytes
                        val out = ByteArray(payload.size + 1)
                        out[0] = if (key) 2 else 3
                        System.arraycopy(payload, 0, out, 1, payload.size)
                        ScreenBridge.emitFrame(out)
                    }
                }
                codec.releaseOutputBuffer(index, false)
            }
        } catch (error: Exception) {
            if (encoding) ScreenBridge.emitText("h264-failed")
        }
    }

    @Synchronized
    private fun stopEncoder() {
        encoding = false
        val codec = encoder
        val surface = encoderSurface
        val thread = encoderThread
        encoder = null
        encoderSurface = null
        encoderThread = null
        try {
            thread?.join(300)
        } catch (error: Exception) {
            // Moving on.
        }
        try {
            codec?.stop()
        } catch (error: Exception) {
            // Already stopped.
        }
        try {
            codec?.release()
        } catch (error: Exception) {
            // Already released.
        }
        try {
            surface?.release()
        } catch (error: Exception) {
            // Already released.
        }
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
            instance = null
            stopEncoder()
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
        @Volatile
        var instance: ScreenCaptureService? = null

        private const val CHANNEL_ID = "zephlink_screen"
        private const val NOTIFICATION_ID = 4712
    }
}
