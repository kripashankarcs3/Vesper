package com.example.wa_shield

import android.media.MediaScannerConnection
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // SECURITY: Block Screenshots, Screen Recording & Hide preview in Recent Apps
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    // Status Saver: lets Dart ask the system media scanner to index a file that
    // was explicitly exported to public storage, so it shows up in the gallery.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wa_shield/media_scanner")
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
    }
}
