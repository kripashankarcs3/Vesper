package com.example.wa_shield

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.FileObserver
import android.os.Handler
import android.os.HandlerThread
import android.os.StatFs
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Native WhatsApp media backup. Runs on its own background thread inside the
 * long-lived listener process, so it works while the Flutter engine is dead.
 *
 * Sources (WhatsApp, legacy WhatsApp and WhatsApp Business):
 *   <Media>/WhatsApp Images, <Media>/WhatsApp Images/Private,
 *   <Media>/WhatsApp Video,  <Media>/WhatsApp Video/Private
 * `Sent/`, `.nomedia`, hidden and temp files are skipped.
 *
 * Policy ([MediaPolicy]): images of any size, videos <= 50 MB; only files
 * modified after a cutoff that is fixed at the first scan (first scan - 7 days)
 * and moved to "now" by a wipe — older history is never bulk-copied. A copy is
 * also skipped if it would leave less than [MIN_FREE_BYTES] free.
 *
 * Files are copied into the app-private `media_vault` (the same directory the
 * Dart side always used: app_flutter/media_vault) and announced through the
 * encrypted event queue. When a backed-up file disappears from every source
 * folder, a `media_del` event flags it "deleted by sender".
 *
 * Detection = FileObserver (CLOSE_WRITE / MOVED_TO / DELETE / MOVED_FROM) on each
 * existing source folder + a periodic full rescan as fallback (FileObserver on
 * FUSE storage is best effort) + a quick rescan after every WhatsApp post.
 */
class MediaBackup private constructor(private val ctx: Context) {
    private val thread = HandlerThread("VesperMedia").apply { start() }
    private val handler = Handler(thread.looper)
    private val observers = HashMap<String, FileObserver>()
    private val prefs = ctx.getSharedPreferences("vesper_media", Context.MODE_PRIVATE)
    @Volatile private var started = false

    private val vaultDir: File get() = File(ctx.getDir("flutter", Context.MODE_PRIVATE), "media_vault")

    fun start() {
        if (started) {
            scheduleRescanSoon(0)
            return
        }
        started = true
        handler.post { rescan() }
        handler.postDelayed(periodic, PERIOD_MS)
    }

    private val periodic = object : Runnable {
        override fun run() {
            rescan()
            handler.postDelayed(this, PERIOD_MS)
        }
    }

    private val quickRescan = Runnable { rescan() }

    fun scheduleRescanSoon(delayMs: Long = 8_000) {
        if (!started) start()
        handler.removeCallbacks(quickRescan)
        handler.postDelayed(quickRescan, delayMs)
    }

    /** Runs [block] on the media thread and waits (used by wipe so it cannot race a copy). */
    fun runSync(block: () -> Unit) {
        val lock = Object()
        var done = false
        handler.post {
            try { block() } finally { synchronized(lock) { done = true; lock.notifyAll() } }
        }
        synchronized(lock) { val end = System.currentTimeMillis() + 10_000
            while (!done && System.currentTimeMillis() < end) lock.wait(500) }
    }

    /** Wipe/Reset: forget flags and move the cutoff to now (nothing older is re-copied). */
    fun resetAfterWipe() = runSync {
        prefs.edit()
            .putLong(KEY_CUTOFF, System.currentTimeMillis())
            .remove(KEY_FLAGGED)
            .apply()
    }

    private fun hasStorageAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) return true
        val perm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE
        return ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
    }

    private fun cutoff(): Long {
        val c = prefs.getLong(KEY_CUTOFF, -1L)
        if (c >= 0) return c
        val now = System.currentTimeMillis()
        val v = now - MediaPolicy.FIRST_SCAN_WINDOW_MS
        prefs.edit().putLong(KEY_CUTOFF, v).apply()
        return v
    }

    // ------------------------------------------------------------- scanning

    private fun rescan() {
        if (!hasStorageAccess()) return
        try {
            val cutoff = cutoff()
            refreshObservers()
            var copied = 0
            for (dir in sourceDirs()) {
                val files = dir.listFiles() ?: continue
                for (f in files) if (f.isFile && backup(f, cutoff)) copied++
            }
            val flagged = checkDeleted()
            if (copied > 0 || flagged > 0) Log.i(TAG, "rescan: $copied backed up, $flagged flagged")
        } catch (e: Exception) {
            Log.e(TAG, "rescan failed: ${e.javaClass.simpleName}")
        }
    }

    private fun sourceDirs(): List<File> = SOURCE_DIRS.map { File(it) }.filter { it.isDirectory }

    /** Copies [src] into the vault if policy allows and it is not there yet. Returns true if copied. */
    private fun backup(src: File, cutoff: Long): Boolean {
        val name = src.name
        if (MediaPolicy.mediaType(name) == null) return false
        val size = src.length()
        if (!MediaPolicy.shouldBackup(name, size, src.lastModified(), cutoff)) return false
        val vault = vaultDir
        if (!vault.exists()) vault.mkdirs()
        val dest = File(vault, name)
        if (dest.exists()) return false
        if (freeBytes(vault) - size < MIN_FREE_BYTES) {
            Log.w(TAG, "skipping backup: low storage")
            return false
        }
        val tmp = File(vault, ".$name.part")
        return try {
            src.inputStream().use { input -> tmp.outputStream().use { input.copyTo(it) } }
            if (tmp.length() != size || !tmp.renameTo(dest)) {
                tmp.delete()
                false
            } else {
                dest.setLastModified(src.lastModified())
                CaptureHub.appendEvent(
                    JSONObject().put("type", "media").put("fileName", name)
                        .put("savedPath", dest.absolutePath)
                        .put("mediaType", MediaPolicy.mediaType(name))
                        .put("ts", System.currentTimeMillis())
                )
                true
            }
        } catch (e: Exception) {
            tmp.delete()
            Log.w(TAG, "copy failed: ${e.javaClass.simpleName}")
            false
        }
    }

    private fun freeBytes(dir: File): Long = try { StatFs(dir.absolutePath).availableBytes } catch (_: Exception) { Long.MAX_VALUE }

    /** Flags vault files whose source vanished from every source folder. */
    private fun checkDeleted(): Int {
        val vaultFiles = vaultDir.listFiles() ?: return 0
        // Only judge when at least one source root is readable; otherwise a
        // missing permission / unmounted storage would flag everything.
        val dirs = sourceDirs()
        if (dirs.isEmpty()) return 0
        val present = HashSet<String>()
        for (d in dirs) d.list()?.let { present.addAll(it) }
        val flagged = prefs.getStringSet(KEY_FLAGGED, emptySet())!!.toMutableSet()
        var n = 0
        for (f in vaultFiles) {
            val name = f.name
            if (name.startsWith(".")) continue
            if (name in present || name in flagged) continue
            flagged.add(name)
            CaptureHub.appendEvent(JSONObject().put("type", "media_del").put("fileName", name))
            n++
        }
        if (n > 0) prefs.edit().putStringSet(KEY_FLAGGED, flagged).apply()
        return n
    }

    // ------------------------------------------------------------- observers

    private fun refreshObservers() {
        val dirs = sourceDirs().map { it.absolutePath }.toSet()
        // Drop observers whose folder vanished.
        val gone = observers.keys - dirs
        gone.forEach { observers.remove(it)?.stopWatching() }
        for (path in dirs) {
            if (observers.containsKey(path)) continue
            val obs = makeObserver(path)
            obs.startWatching()
            observers[path] = obs
        }
    }

    private fun makeObserver(path: String): FileObserver {
        val mask = FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.DELETE_SELF
        val cb: (Int, String?) -> Unit = { event, name ->
            if (name != null) handler.post { onFsEvent(path, event, name) }
            else if (event and FileObserver.DELETE_SELF != 0) handler.post { refreshObservers() }
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            object : FileObserver(File(path), mask) {
                override fun onEvent(event: Int, p: String?) = cb(event, p)
            }
        } else {
            @Suppress("DEPRECATION")
            object : FileObserver(path, mask) {
                override fun onEvent(event: Int, p: String?) = cb(event, p)
            }
        }
    }

    private fun onFsEvent(dir: String, event: Int, name: String) {
        if (!hasStorageAccess()) return
        val ev = event and FileObserver.ALL_EVENTS
        if (ev and (FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO) != 0) {
            val f = File(dir, name)
            if (f.isFile) {
                // Wait until the size is stable (WhatsApp may still be writing).
                val s1 = f.length()
                handler.postDelayed({
                    if (f.isFile && f.length() == s1) backup(f, cutoff()) else scheduleRescanSoon(3_000)
                }, 1_500)
            }
        } else if (ev and (FileObserver.DELETE or FileObserver.MOVED_FROM) != 0) {
            handler.postDelayed({ checkDeleted() }, 1_000)
        }
    }

    companion object {
        private const val TAG = "VesperMedia"
        private const val KEY_CUTOFF = "cutoff_ms"
        private const val KEY_FLAGGED = "flagged"
        private const val PERIOD_MS = 3L * 60 * 1000
        private const val MIN_FREE_BYTES = 1024L * 1024 * 1024 // keep >= 1 GB free

        private val MEDIA_ROOTS = listOf(
            "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media" to "WhatsApp",
            "/storage/emulated/0/WhatsApp/Media" to "WhatsApp",
            "/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media" to "WhatsApp Business",
            "/storage/emulated/0/WhatsApp Business/Media" to "WhatsApp Business",
        )

        val SOURCE_DIRS: List<String> = MEDIA_ROOTS.flatMap { (root, prefix) ->
            listOf(
                "$root/$prefix Images",
                "$root/$prefix Images/Private",
                "$root/$prefix Video",
                "$root/$prefix Video/Private",
            )
        }

        @Volatile private var instance: MediaBackup? = null

        fun get(context: Context): MediaBackup =
            instance ?: synchronized(this) {
                instance ?: MediaBackup(context.applicationContext).also { instance = it }
            }
    }
}
