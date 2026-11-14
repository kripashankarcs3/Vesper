import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'db_helper.dart';

/// Decodes one queued native event (JSON). Returns null for malformed input.
/// PURE — unit tested.
Map<String, dynamic>? decodeCaptureEvent(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final v = jsonDecode(raw);
    if (v is Map<String, dynamic> && v['type'] is String) return v;
  } catch (_) {}
  return null;
}

/// Dart side of the native capture pipeline (CaptureListenerService /
/// CaptureHub / MediaBackup in Kotlin).
///
/// The native side writes every captured event (new message, deletion, media
/// backed up / gone) to an encrypted, app-private queue — also while the
/// Flutter engine is not running. Dart drains that queue on startup, on resume
/// and whenever native pings "changed", applies the events idempotently to the
/// SQLCipher vault, and only then acks them.
class CaptureBridge {
  CaptureBridge._();

  static const MethodChannel _ch = MethodChannel('vesper/capture');
  static const EventChannel _events = EventChannel('vesper/capture_events');

  static Future<int>? _draining;
  static bool _drainAgain = false;

  /// Live "something was captured" pings (no payload).
  static Stream<void> get changes => _events.receiveBroadcastStream().map((_) {});

  static Future<bool> isListenerEnabled() async {
    try {
      return await _ch.invokeMethod<bool>('isListenerEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openListenerSettings() => _safe('openListenerSettings');
  static Future<void> requestRebind() => _safe('requestRebind');
  static Future<void> startMedia() => _safe('startMedia');
  static Future<void> rescanMedia() => _safe('rescanMedia');

  /// Wipe / Reset: clears the native queue, chat snapshots, reply actions and
  /// media flags (and moves the media cutoff to now).
  static Future<void> clearCaptureState() async {
    await _ch.invokeMethod('clearCaptureState');
  }

  static Future<Set<String>> replyableChats() async {
    try {
      final l = await _ch.invokeListMethod<String>('replyableChats');
      return (l ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<bool> sendReply(String chatKey, String text) async {
    try {
      return await _ch.invokeMethod<bool>('sendReply', {'chatKey': chatKey, 'text': text}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Drains the native queue into the vault. Single-flight: concurrent callers
  /// share the running drain, and a request that arrives meanwhile triggers one
  /// more pass. Returns the number of DB rows changed. Throws if the vault
  /// cannot be opened (events then stay queued).
  static Future<int> drain() {
    final running = _draining;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    final f = _drainLoop();
    _draining = f;
    f.then((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_draining, f)) _draining = null;
    });
    return f;
  }

  static Future<int> _drainLoop() async {
    var total = 0;
    do {
      _drainAgain = false;
      total += await _drainOnce();
    } while (_drainAgain);
    return total;
  }

  static Future<int> _drainOnce() async {
    final res = await _ch.invokeMapMethod<String, dynamic>('drainQueue');
    if (res == null) return 0;
    final count = (res['count'] as num?)?.toInt() ?? 0;
    if (count == 0) return 0;
    final generation = res['generation'];
    final events = <Map<String, dynamic>>[];
    for (final raw in (res['events'] as List? ?? const [])) {
      final e = decodeCaptureEvent(raw);
      if (e != null) events.add(e);
    }
    // Store first, ack after: a crash in between only replays idempotent events.
    final changed = await DBHelper.instance.applyCaptureEvents(events);
    await _ch.invokeMethod('ackQueue', {'generation': generation, 'count': count});
    debugPrint('Vesper: drained $count queued event(s), $changed change(s)');
    return changed;
  }

  static Future<void> _safe(String method) async {
    try {
      await _ch.invokeMethod(method);
    } catch (e) {
      debugPrint('Vesper: $method failed: $e');
    }
  }
}
