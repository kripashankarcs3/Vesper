package com.example.wa_shield

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * Vesper's own notification listener. The system binds it in our process for as
 * long as notification access is granted (and re-binds it after the process is
 * killed), so capture works even when the Flutter engine / UI is not running.
 * Everything it captures goes into the encrypted [SecureEventQueue] via
 * [CaptureHub]; Dart drains the queue when it runs.
 *
 * It also hosts the native media watcher ([MediaBackup]) because this is the
 * long-lived component of the process.
 */
class CaptureListenerService : NotificationListenerService() {

    override fun onCreate() {
        super.onCreate()
        CaptureHub.init(this)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "listener connected")
        connected = true
        MediaBackup.get(this).start()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        connected = false
        Log.i(TAG, "listener disconnected; requesting rebind")
        try {
            requestRebind(ComponentName(this, CaptureListenerService::class.java))
        } catch (_: Exception) {
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        if (!NotificationParser.isSupportedPackage(sbn.packageName)) return
        try {
            val parsed = NotificationParser.parse(sbn) ?: return
            CaptureHub.onNotificationPosted(parsed, sbn.key, sbn.notification)
            // A WhatsApp message may come with media that is downloaded shortly
            // after the notification: schedule a quick media rescan.
            if (!parsed.isGroupSummary) MediaBackup.get(this).scheduleRescanSoon()
        } catch (e: Exception) {
            Log.e(TAG, "posted handling failed: ${e.javaClass.simpleName}")
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?, rankingMap: RankingMap?, reason: Int) {
        sbn ?: return
        if (!NotificationParser.isSupportedPackage(sbn.packageName)) return
        try {
            val parsed = try {
                NotificationParser.parse(sbn)
            } catch (_: Exception) {
                null
            }
            CaptureHub.onNotificationRemoved(sbn.key, parsed, reason)
        } catch (e: Exception) {
            Log.e(TAG, "removed handling failed: ${e.javaClass.simpleName}")
        }
    }

    companion object {
        private const val TAG = "VesperListener"

        @Volatile
        var connected = false
            private set

        fun component(context: Context) = ComponentName(context, CaptureListenerService::class.java)

        /** True when our component is listed in Settings.Secure "enabled_notification_listeners". */
        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
                ?: return false
            val me = component(context)
            return flat.split(":").any { s ->
                val cn = ComponentName.unflattenFromString(s)
                cn != null && cn == me
            }
        }
    }
}
