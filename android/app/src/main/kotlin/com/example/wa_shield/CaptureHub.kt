package com.example.wa_shield

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Process-wide capture state shared by [CaptureListenerService], [MediaBackup]
 * and [MainActivity]:
 *  - the snapshot tracker (persisted encrypted so deletions survive restarts),
 *  - the encrypted event queue (the single source of truth for Dart),
 *  - the latest Ghost Reply action per chat (in memory only: PendingIntents
 *    cannot be persisted),
 *  - a "changed" listener that pings Dart while the engine is running.
 *
 * NEVER log message text here.
 */
object CaptureHub {
    private const val TAG = "VesperCapture"

    @Volatile
    private var appContext: Context? = null
    private lateinit var queue: SecureEventQueue
    private lateinit var snapshotBlob: SecureBlob
    private lateinit var tracker: ChatSnapshotTracker

    /** sbn.key -> chatKey, so removals can be mapped even if their extras differ. */
    private val keyToChat = HashMap<String, String>()
    private val replyActions = HashMap<String, Notification.Action>()

    /** Bumped on every clear so a stale ack cannot drop newer events. */
    @Volatile
    var generation: Long = 0
        private set

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var onChanged: (() -> Unit)? = null

    @Synchronized
    fun init(context: Context) {
        if (appContext != null) return
        val ctx = context.applicationContext
        queue = SecureEventQueue(ctx)
        snapshotBlob = SecureBlob(ctx, "capture_snapshots.enc")
        tracker = ChatSnapshotTracker(loadSnapshots())
        appContext = ctx
    }

    // ---------------------------------------------------------------- events

    fun onNotificationPosted(parsed: ParsedNotification, sbnKey: String, notification: Notification) {
        val events: List<CaptureEvent>
        synchronized(this) {
            keyToChat[sbnKey] = parsed.chatKey
            if (!parsed.isGroupSummary) {
                NotificationParser.replyAction(notification)?.let { replyActions[parsed.chatKey] = it }
            }
            events = tracker.onPosted(parsed)
            if (events.isNotEmpty() || parsed.messages.isNotEmpty()) saveSnapshots()
        }
        if (events.isNotEmpty()) {
            events.forEach { appendEvent(eventToJson(it)) }
            val news = events.count { it is CaptureEvent.NewMessage }
            Log.i(TAG, "captured: ${news} new, ${events.size - news} deletion event(s)")
        }
    }

    fun onNotificationRemoved(sbnKey: String, parsed: ParsedNotification?, reason: Int) {
        synchronized(this) {
            val chatKey = keyToChat.remove(sbnKey) ?: parsed?.chatKey ?: return
            if (parsed?.isGroupSummary == true) return
            tracker.onRemoved(chatKey)
            saveSnapshots()
            Log.i(TAG, "chat notification removed (reason=$reason): snapshot reset, no deletions")
        }
    }

    fun appendEvent(json: JSONObject) {
        try {
            queue.append(json.toString())
        } catch (e: Exception) {
            Log.e(TAG, "queue append failed: ${e.javaClass.simpleName}")
            return
        }
        main.post { onChanged?.invoke() }
    }

    private fun eventToJson(e: CaptureEvent): JSONObject = when (e) {
        is CaptureEvent.NewMessage -> JSONObject()
            .put("type", "msg").put("uid", e.uid).put("pkg", e.packageName)
            .put("chatKey", e.chatKey).put("chatTitle", e.chatTitle).put("isGroup", e.isGroup)
            .put("sender", e.sender).put("text", e.text).put("ts", e.timestamp)
        is CaptureEvent.Deleted -> JSONObject()
            .put("type", "del").put("uid", e.uid).put("pkg", e.packageName).put("chatKey", e.chatKey)
            .put("at", System.currentTimeMillis())
        is CaptureEvent.DeleteLatestFromSender -> JSONObject()
            .put("type", "del_latest").put("pkg", e.packageName).put("chatKey", e.chatKey)
            .put("sender", e.sender).put("beforeTs", e.beforeTs)
    }

    // ---------------------------------------------------------------- Dart API

    /** {generation, count, events:[json strings]} */
    fun drain(): Map<String, Any> {
        val gen = generation
        val (events, count) = queue.readAll()
        return mapOf("generation" to gen, "count" to count, "events" to events)
    }

    fun ack(gen: Long, count: Int) {
        synchronized(this) {
            if (gen != generation) return
            queue.ack(count)
        }
    }

    fun replyableChats(): List<String> = synchronized(this) { replyActions.keys.toList() }

    /** Ghost Reply: fires the chat's stored RemoteInput action without opening WhatsApp. */
    fun sendReply(context: Context, chatKey: String, text: String): Boolean {
        val action = synchronized(this) { replyActions[chatKey] } ?: return false
        val inputs = action.remoteInputs ?: return false
        val intent = Intent()
        val bundle = Bundle()
        for (ri in inputs) bundle.putCharSequence(ri.resultKey, text)
        RemoteInput.addResultsToIntent(inputs, intent, bundle)
        return try {
            action.actionIntent.send(context, 0, intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "ghost reply failed: ${e.javaClass.simpleName}")
            synchronized(this) { replyActions.remove(chatKey) }
            false
        }
    }

    /** Wipe / Reset: drop queued events, snapshots and reply actions. */
    fun clearAll() {
        synchronized(this) {
            generation++
            queue.clear()
            tracker.clear()
            snapshotBlob.delete()
            keyToChat.clear()
            replyActions.clear()
        }
    }

    fun queueSize(): Int = queue.size()

    // ---------------------------------------------------------------- persistence

    private fun saveSnapshots() {
        try {
            val root = JSONObject()
            for ((chat, entries) in tracker.export()) {
                val arr = JSONArray()
                for (e in entries) {
                    arr.put(JSONObject().put("u", e.uid).put("t", e.timestamp).put("s", e.sender).put("m", e.marker))
                }
                root.put(chat, arr)
            }
            snapshotBlob.write(root.toString())
        } catch (e: Exception) {
            Log.w(TAG, "snapshot save failed: ${e.javaClass.simpleName}")
        }
    }

    private fun loadSnapshots(): Map<String, List<SnapshotEntry>> {
        return try {
            val raw = snapshotBlob.read() ?: return emptyMap()
            val root = JSONObject(raw)
            val out = LinkedHashMap<String, List<SnapshotEntry>>()
            for (chat in root.keys()) {
                val arr = root.getJSONArray(chat)
                out[chat] = (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    SnapshotEntry(o.getString("u"), o.getLong("t"), o.getString("s"), o.optBoolean("m", false))
                }
            }
            out
        } catch (e: Exception) {
            Log.w(TAG, "snapshot load failed: ${e.javaClass.simpleName}")
            emptyMap()
        }
    }
}
