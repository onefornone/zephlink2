package app.zephlink.zephlink

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Telephony
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * "zephlink/phone": text messages and calls for the linked PC.
 *  - read the conversation list and one conversation
 *  - send a text message
 *  - tell Dart when a text arrives or a call rings, starts or ends
 *  - answer or decline a ringing call
 * Android asks the person for each permission; nothing here works without it.
 */
object PhoneBridge {
    private const val REQUEST_PERMISSIONS = 4910

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var smsReceiver: BroadcastReceiver? = null
    private var phoneReceiver: BroadcastReceiver? = null
    private val names = HashMap<String, String>()

    fun register(host: Activity, messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, "zephlink/phone")
        channel = methodChannel
        registerReceivers(host)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "perms" -> result.success(
                    mapOf(
                        "sms" to has(host, "sms"),
                        "calls" to has(host, "calls"),
                        "contacts" to has(host, "contacts")
                    )
                )
                "request" -> request(host, call.argument<String>("group") ?: "", result)
                "conversations" -> background(result) {
                    conversations(host, call.argument<Int>("limit") ?: 60)
                }
                "thread" -> background(result) {
                    thread(host, (call.argument<Number>("thread") ?: 0).toLong(), call.argument<Int>("limit") ?: 150)
                }
                "send" -> background(result) {
                    send(host, call.argument<String>("to") ?: "", call.argument<String>("text") ?: "")
                }
                "answer" -> result.success(callAction(host, true))
                "reject" -> result.success(callAction(host, false))
                else -> result.notImplemented()
            }
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: SecurityException) {
                main.post { result.error("denied", "Android did not allow that.", null) }
            } catch (error: Exception) {
                main.post { result.error("failed", error.message ?: "Failed", null) }
            }
        }.start()
    }

    private fun permissionsFor(group: String): Array<String> {
        return when (group) {
            "sms" -> arrayOf(
                Manifest.permission.READ_SMS,
                Manifest.permission.SEND_SMS,
                Manifest.permission.RECEIVE_SMS
            )
            "calls" -> if (Build.VERSION.SDK_INT >= 26) {
                arrayOf(
                    Manifest.permission.READ_PHONE_STATE,
                    Manifest.permission.READ_CALL_LOG,
                    Manifest.permission.ANSWER_PHONE_CALLS
                )
            } else {
                arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG)
            }
            "contacts" -> arrayOf(Manifest.permission.READ_CONTACTS)
            else -> arrayOf()
        }
    }

    private fun has(context: Context, group: String): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        for (permission in permissionsFor(group)) {
            if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                return false
            }
        }
        return true
    }

    private fun request(host: Activity, group: String, result: MethodChannel.Result) {
        val wanted = permissionsFor(group)
        if (wanted.isEmpty() || Build.VERSION.SDK_INT < 23 || has(host, group)) {
            result.success(true)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "Already waiting for an answer.", null)
            return
        }
        pendingResult = result
        host.requestPermissions(wanted, REQUEST_PERMISSIONS)
    }

    fun handlePermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_PERMISSIONS) return
        val result = pendingResult ?: return
        pendingResult = null
        names.clear()
        var all = grantResults.isNotEmpty()
        for (grant in grantResults) {
            if (grant != PackageManager.PERMISSION_GRANTED) all = false
        }
        result.success(all)
    }

    private fun nameFor(context: Context, number: String): String {
        if (number.isEmpty()) return ""
        val known = names[number]
        if (known != null) return known
        var name = ""
        if (has(context, "contacts")) {
            try {
                val uri = Uri.withAppendedPath(
                    ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                    Uri.encode(number)
                )
                val cursor = context.contentResolver.query(
                    uri,
                    arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                    null,
                    null,
                    null
                )
                if (cursor != null) {
                    cursor.use {
                        if (it.moveToFirst()) name = it.getString(0) ?: ""
                    }
                }
            } catch (error: Exception) {
                // No name; the number is shown instead.
            }
        }
        names[number] = name
        return name
    }

    private fun conversations(context: Context, limit: Int): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val seen = HashSet<Long>()
        val cursor = context.contentResolver.query(
            Uri.parse("content://sms"),
            arrayOf("thread_id", "address", "body", "date", "type", "read"),
            null,
            null,
            "date DESC"
        ) ?: return out
        cursor.use {
            while (it.moveToNext() && out.size < limit) {
                val thread = it.getLong(0)
                if (!seen.add(thread)) continue
                val address = it.getString(1) ?: ""
                var snippet = it.getString(2) ?: ""
                if (snippet.length > 120) snippet = snippet.substring(0, 120)
                out.add(
                    mapOf(
                        "t" to thread,
                        "a" to address,
                        "n" to nameFor(context, address),
                        "s" to snippet,
                        "d" to it.getLong(3),
                        "o" to (it.getInt(4) == 2),
                        "u" to (it.getInt(5) == 0 && it.getInt(4) == 1)
                    )
                )
            }
        }
        return out
    }

    private fun thread(context: Context, thread: Long, limit: Int): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        val cursor = context.contentResolver.query(
            Uri.parse("content://sms"),
            arrayOf("_id", "body", "date", "type"),
            "thread_id = ?",
            arrayOf(thread.toString()),
            "date DESC"
        ) ?: return out
        cursor.use {
            while (it.moveToNext() && out.size < limit) {
                out.add(
                    mapOf(
                        "i" to it.getLong(0),
                        "b" to (it.getString(1) ?: ""),
                        "d" to it.getLong(2),
                        "o" to (it.getInt(3) != 1)
                    )
                )
            }
        }
        out.reverse()
        return out
    }

    private fun send(context: Context, to: String, text: String): String? {
        if (to.isBlank() || text.isEmpty()) return "There is nothing to send."
        if (!has(context, "sms")) return "Allow text messages for Zephlink on the phone first."
        val sms: SmsManager? = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        if (sms == null) return "This device cannot send text messages."
        val parts = sms.divideMessage(text)
        if (parts.size > 1) {
            sms.sendMultipartTextMessage(to, null, parts, null, null)
        } else {
            sms.sendTextMessage(to, null, text, null, null)
        }
        return null
    }

    private fun callAction(context: Context, answer: Boolean): String? {
        if (!has(context, "calls")) return "Allow phone access for Zephlink on the phone first."
        try {
            val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            if (answer) {
                if (Build.VERSION.SDK_INT < 26) return "Android 8 or newer is needed to answer from the PC."
                telecom.acceptRingingCall()
                return null
            }
            if (Build.VERSION.SDK_INT < 28) return "Android 9 or newer is needed to decline from the PC."
            return if (telecom.endCall()) null else "There is no call to end."
        } catch (error: SecurityException) {
            return "Android did not allow that."
        } catch (error: Exception) {
            return "Could not do that."
        }
    }

    private fun emit(event: Map<String, Any>) {
        main.post { channel?.invokeMethod("event", event) }
    }

    private fun registerCompat(context: Context, receiver: BroadcastReceiver, filter: IntentFilter) {
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    private fun registerReceivers(host: Activity) {
        val app = host.applicationContext
        if (smsReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    try {
                        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
                        if (messages == null || messages.isEmpty()) return
                        val address = messages[0].originatingAddress ?: ""
                        val body = StringBuilder()
                        for (message in messages) body.append(message.messageBody ?: "")
                        emit(
                            mapOf(
                                "kind" to "sms",
                                "a" to address,
                                "n" to nameFor(context, address),
                                "b" to body.toString(),
                                "d" to messages[0].timestampMillis
                            )
                        )
                    } catch (error: Exception) {
                        // A message we cannot read is skipped.
                    }
                }
            }
            try {
                registerCompat(app, receiver, IntentFilter("android.provider.Telephony.SMS_RECEIVED"))
                smsReceiver = receiver
            } catch (error: Exception) {
                // Texts will not be forwarded.
            }
        }
        if (phoneReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    try {
                        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
                        @Suppress("DEPRECATION")
                        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: ""
                        val label = when (state) {
                            TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
                            TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"
                            else -> "idle"
                        }
                        emit(
                            mapOf(
                                "kind" to "call",
                                "st" to label,
                                "a" to number,
                                "n" to nameFor(context, number)
                            )
                        )
                    } catch (error: Exception) {
                        // A call event we cannot read is skipped.
                    }
                }
            }
            try {
                registerCompat(app, receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED))
                phoneReceiver = receiver
            } catch (error: Exception) {
                // Calls will not be forwarded.
            }
        }
    }
}
