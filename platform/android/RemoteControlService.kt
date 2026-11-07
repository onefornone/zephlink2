package app.zephlink.zephlink

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Lets a PC that the phone's owner has allowed tap, swipe and type on this
 * phone. It does nothing until the owner turns it on in Android's
 * Accessibility settings, and Zephlink only uses it while control is allowed.
 */
class RemoteControlService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Zephlink does not read what is on the screen through this service.
    }

    override fun onInterrupt() {}

    /** A tap (same start and end) or a swipe, in screen pixels. */
    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val path = Path()
        path.moveTo(x1, y1)
        if (x1 != x2 || y1 != y2) path.lineTo(x2, y2)
        val stroke = GestureDescription.StrokeDescription(path, 0L, Math.max(1L, durationMs))
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGesture(gesture, null, null)
    }

    fun navigate(action: String): Boolean {
        val code = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quicksettings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "power" -> GLOBAL_ACTION_POWER_DIALOG
            "lock" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
                GLOBAL_ACTION_LOCK_SCREEN
            }
            "screenshot" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
                GLOBAL_ACTION_TAKE_SCREENSHOT
            }
            else -> return false
        }
        return performGlobalAction(code)
    }

    /** Adds text to the field that has the cursor. */
    fun typeText(text: String): Boolean {
        if (text.isEmpty()) return false
        val root = rootInActiveWindow ?: return false
        val field = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        var existing = field.text?.toString() ?: ""
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && field.isShowingHintText) {
            existing = ""
        }
        val arguments = Bundle()
        arguments.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            existing + text
        )
        return field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    companion object {
        @Volatile
        var instance: RemoteControlService? = null
    }
}
