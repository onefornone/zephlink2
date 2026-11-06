package app.zephlink.zephlink

import android.app.Notification
import android.app.NotificationListenerService
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.StatusBarNotification
import java.security.MessageDigest
import java.util.UUID

object NotificationForwardingStore {
    private const val PREFERENCES = "FlutterSharedPreferences"
    private const val ENABLED_KEY = "flutter.zl_forward_notifications"
    private const val MAX_EVENTS = 200
    private const val MAX_TEXT_LENGTH = 4096

    private val lock = Any()
    private val events = mutableListOf<Map<String, Any>>()
    private val notificationKeys = mutableMapOf<String, String>()

    @Volatile
    private var service: NotificationForwardingService? = null

    fun onConnected(listener: NotificationForwardingService) {
        service = listener
        listener.publishActiveNotifications()
    }

    fun onDisconnected(listener: NotificationForwardingService) {
        if (service === listener) service = null
    }

    fun hasAccess(context: Context): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        return enabled.split(':').any { flattened ->
            val component = ComponentName.unflattenFromString(flattened)
            component?.packageName == context.packageName &&
                component.className == NotificationForwardingService::class.java.name
        }
    }

    fun openSettings(context: Context) {
        context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ENABLED_KEY, enabled)
            .apply()
        if (!enabled) {
            synchronized(lock) {
                events.clear()
                notificationKeys.clear()
            }
        } else {
            service?.publishActiveNotifications()
        }
    }

    fun pending(): List<Map<String, Any>> = synchronized(lock) {
        events.map { HashMap(it) }
    }

    fun acknowledge(eventId: String) {
        synchronized(lock) {
            events.removeAll { it["eventId"] == eventId }
        }
    }

    fun onPosted(context: Context, notification: StatusBarNotification) {
        if (!isEnabled(context) || notification.packageName == context.packageName) return

        val id = stableId(notification.key)
        val extras = notification.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)
            ?.toString()
            .orEmpty()
            .take(512)
        val text = notificationText(extras).take(MAX_TEXT_LENGTH)
        if (title.isEmpty() && text.isEmpty()) return

        val app = try {
            context.packageManager.getApplicationLabel(
                context.packageManager.getApplicationInfo(notification.packageName, 0)
            ).toString()
        } catch (_: Exception) {
            notification.packageName
        }.take(128)
        val canReply = notification.notification.actions
            ?.any { action ->
                action.remoteInputs?.any { it.allowFreeFormInput } == true
            } == true

        synchronized(lock) {
            events.removeAll { it["id"] == id }
            notificationKeys[id] = notification.key
            events.add(
                mapOf(
                    "type" to "posted",
                    "eventId" to UUID.randomUUID().toString(),
                    "id" to id,
                    "app" to app,
                    "title" to title,
                    "text" to text,
                    "canReply" to canReply,
                    "time" to notification.postTime,
                )
            )
            trimEvents()
        }
    }

    fun onRemoved(context: Context, notification: StatusBarNotification) {
        if (!isEnabled(context) || notification.packageName == context.packageName) return
        val id = stableId(notification.key)
        synchronized(lock) {
            if (notificationKeys.remove(id) == null) return
            events.removeAll { it["id"] == id }
            events.add(
                mapOf(
                    "type" to "removed",
                    "eventId" to UUID.randomUUID().toString(),
                    "id" to id,
                )
            )
            trimEvents()
        }
    }

    fun reply(context: Context, id: String, text: String): Boolean {
        if (text.isBlank() || text.length > 2000) return false
        val listener = service ?: return false
        val key = synchronized(lock) { notificationKeys[id] } ?: return false
        val notification = listener.activeNotifications
            ?.firstOrNull { it.key == key }
            ?: return false
        val action = notification.notification.actions
            ?.firstOrNull { candidate ->
                candidate.remoteInputs?.any { it.allowFreeFormInput } == true
            }
            ?: return false
        val remoteInputs = action.remoteInputs ?: return false
        val replyInput = remoteInputs.firstOrNull { it.allowFreeFormInput } ?: return false
        val intent = Intent()
        val results = Bundle().apply {
            putCharSequence(replyInput.resultKey, text)
        }
        RemoteInput.addResultsToIntent(remoteInputs, intent, results)
        return try {
            action.actionIntent.send(context, 0, intent)
            true
        } catch (_: PendingIntent.CanceledException) {
            false
        }
    }

    fun dismiss(context: Context, id: String): Boolean {
        val listener = service ?: return false
        val key = synchronized(lock) { notificationKeys.remove(id) } ?: return false
        listener.cancelNotification(key)
        return true
    }

    private fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getBoolean(ENABLED_KEY, false)

    private fun notificationText(extras: Bundle): String {
        val mainText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)
        if (!mainText.isNullOrBlank()) return mainText.toString()
        return extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.joinToString("\n") { it.toString() }
            .orEmpty()
    }

    private fun stableId(key: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(key.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun trimEvents() {
        while (events.size > MAX_EVENTS) events.removeAt(0)
    }
}

class NotificationForwardingService : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        NotificationForwardingStore.onConnected(this)
    }

    override fun onListenerDisconnected() {
        NotificationForwardingStore.onDisconnected(this)
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(notification: StatusBarNotification) {
        NotificationForwardingStore.onPosted(this, notification)
    }

    override fun onNotificationRemoved(notification: StatusBarNotification) {
        NotificationForwardingStore.onRemoved(this, notification)
    }

    internal fun publishActiveNotifications() {
        activeNotifications?.forEach { NotificationForwardingStore.onPosted(this, it) }
    }
}
