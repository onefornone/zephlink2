package app.zephlink.zephlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder

/**
 * Keeps Zephlink running with a small notification, and keeps Wi-Fi awake,
 * so your phone stays linked to your PC when the screen is off.
 */
class KeepAliveService : Service() {
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Zephlink link",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Shown while Zephlink keeps your devices linked"
            manager.createNotificationChannel(channel)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("Zephlink is running")
            .setContentText("Keeping your devices linked")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            val pending = PendingIntent.getActivity(
                this,
                0,
                launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            builder.setContentIntent(pending)
        }
        val notification = builder.build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireWifiLock()
        return START_STICKY
    }

    @Suppress("DEPRECATION")
    private fun acquireWifiLock() {
        if (wifiLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "zephlink:link")
        lock.setReferenceCounted(false)
        lock.acquire()
        wifiLock = lock
    }

    override fun onDestroy() {
        val lock = wifiLock
        if (lock != null && lock.isHeld) {
            lock.release()
        }
        wifiLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "zephlink_link"
        private const val NOTIFICATION_ID = 4711
    }
}
