import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'capture_bridge.dart';

/// WhatsApp media backup.
///
/// Watching, copying and "removed from WhatsApp" detection now run natively
/// (MediaBackup.kt, inside the long-lived notification-listener process) so
/// they keep working while the Flutter engine is dead. They cover
/// `WhatsApp Images[/Private]` and `WhatsApp Video[/Private]` for WhatsApp and
/// WhatsApp Business, back up images of any size and videos up to 50 MB, and
/// never bulk-copy history older than 7 days before the first scan. Results
/// reach the vault DB through the encrypted capture queue ([CaptureBridge]).
///
/// This class keeps the Dart-facing API: start / rescan and wiping the
/// app-private `media_vault` directory.
class MediaWatcherService {
  static final MediaWatcherService _instance = MediaWatcherService._internal();
  factory MediaWatcherService() => _instance;
  MediaWatcherService._internal();

  /// Starts (or nudges) the native watcher. Safe to call repeatedly.
  Future<void> startWatching() async {
    await CaptureBridge.startMedia();
  }

  Future<void> rescan() => CaptureBridge.rescanMedia();

  /// Deletes EVERY file under the app-private media_vault directory — including
  /// orphans not represented in the DB — so a "wipe" actually removes the
  /// backed-up images/videos from disk, not just their database rows.
  /// Returns true only if the directory ends up empty. Throws on hard failure.
  Future<bool> deleteAllBackedUpMedia() async {
    final appDir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(join(appDir.path, 'media_vault'));
    if (!await vaultDir.exists()) return true;

    await for (final entity in vaultDir.list()) {
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        debugPrint("Media wipe: failed to delete ${entity.path}: $e");
      }
    }
    // Report whether anything survived (e.g. a locked/undeletable file).
    final remaining = await vaultDir.list().length;
    return remaining == 0;
  }
}
