package com.example.wa_shield

import android.content.Intent
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val io = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // SECURITY: Block Screenshots, Screen Recording & Hide preview in Recent Apps
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CaptureHub.init(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Status Saver: lets Dart ask the system media scanner to index a file that
        // was explicitly exported to public storage, so it shows up in the gallery.
        MethodChannel(messenger, "wa_shield/media_scanner")
            .setMethodCallHandler { call, result ->
                if (call.method == "scanFile") {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "path is required", null)
                    } else {
                        MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null, null)
                        result.success(true)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Native capture bridge (see CaptureHub / CaptureListenerService / MediaBackup).
        MethodChannel(messenger, "vesper/capture").setMethodCallHandler { call, result ->
            when (call.method) {
                "isListenerEnabled" -> result.success(CaptureListenerService.isEnabled(this))
                "openListenerSettings" -> {
                    openListenerSettings()
                    result.success(true)
                }
                "requestRebind" -> {
                    if (CaptureListenerService.isEnabled(this) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        try {
                            NotificationListenerService.requestRebind(CaptureListenerService.component(this))
                        } catch (_: Exception) {
                        }
                    }
                    result.success(true)
                }
                "startMedia" -> {
                    MediaBackup.get(this).start()
                    result.success(true)
                }
                "rescanMedia" -> {
                    MediaBackup.get(this).scheduleRescanSoon(0)
                    result.success(true)
                }
                "drainQueue" -> io.execute {
                    val r = try {
                        CaptureHub.drain()
                    } catch (e: Exception) {
                        null
                    }
                    runOnUiThread {
                        if (r == null) result.error("DRAIN_FAILED", "queue could not be read", null)
                        else result.success(r)
                    }
                }
                "ackQueue" -> {
                    val gen = (call.argument<Number>("generation") ?: -1).toLong()
                    val count = call.argument<Int>("count") ?: 0
                    io.execute {
                        CaptureHub.ack(gen, count)
                        runOnUiThread { result.success(true) }
                    }
                }
                "replyableChats" -> result.success(CaptureHub.replyableChats())
                "sendReply" -> {
                    val chatKey = call.argument<String>("chatKey")
                    val text = call.argument<String>("text")
                    if (chatKey.isNullOrEmpty() || text.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "chatKey and text are required", null)
                    } else {
                        result.success(CaptureHub.sendReply(this, chatKey, text))
                    }
                }
                "clearCaptureState" -> io.execute {
                    // Wipe / Reset: queue, snapshots, reply actions, media flags + cutoff.
                    CaptureHub.clearAll()
                    MediaBackup.get(this).resetAfterWipe()
                    runOnUiThread { result.success(true) }
                }
                else -> result.notImplemented()
            }
        }

        // Live "something was captured" pings while the engine runs. Payload-free:
        // Dart reacts by draining the encrypted queue (single, idempotent path).
        EventChannel(messenger, "vesper/capture_events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                val cb: () -> Unit = { events?.success("changed") }
                changedCallback = cb
                CaptureHub.onChanged = cb
            }

            override fun onCancel(arguments: Any?) {
                clearChangedCallback()
            }
        })
    }

    private var changedCallback: (() -> Unit)? = null

    /** Only unregister our own callback (a newer activity may have replaced it). */
    private fun clearChangedCallback() {
        if (CaptureHub.onChanged === changedCallback) CaptureHub.onChanged = null
        changedCallback = null
    }

    override fun onDestroy() {
        clearChangedCallback()
        super.onDestroy()
    }

    private fun openListenerSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(
                Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                CaptureListenerService.component(this).flattenToString()
            )
        } else {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        }
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}
