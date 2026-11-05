import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'db_helper.dart';

class MediaWatcherService {
  static final MediaWatcherService _instance = MediaWatcherService._internal();
  factory MediaWatcherService() => _instance;
  MediaWatcherService._internal();

  final List<StreamSubscription<FileSystemEvent>> _subscriptions = [];
  Timer? _pollingTimer;
  bool _isWatching = false;

  final List<String> _whatsappPaths = [
    '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images',
    '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video',
    '/storage/emulated/0/WhatsApp/Media/WhatsApp Images',
    '/storage/emulated/0/WhatsApp/Media/WhatsApp Video',
    '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images',
    '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Video',
  ];

  Future<void> startWatching({required VoidCallback onMediaUpdate}) async {
    if (_isWatching) return;
    _isWatching = true;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final vaultDir = Directory(join(appDir.path, 'media_vault'));
      if (!await vaultDir.exists()) {
        await vaultDir.create(recursive: true);
      }

      for (final p in _whatsappPaths) {
        final dir = Directory(p);
        if (await dir.exists()) {
          final sub = dir.watch(events: FileSystemEvent.all, recursive: false).listen((event) async {
            await _handleFileSystemEvent(event, vaultDir, onMediaUpdate);
          });
          _subscriptions.add(sub);
        }
      }

      // Fallback periodic sync for media additions/deletions
      _pollingTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        await _scanExistingMedia(vaultDir, onMediaUpdate);
      });

      await _scanExistingMedia(vaultDir, onMediaUpdate);
    } catch (e) {
      debugPrint("MediaWatcherService error: $e");
    }
  }

  Future<void> _handleFileSystemEvent(
    FileSystemEvent event,
    Directory vaultDir,
    VoidCallback onMediaUpdate,
  ) async {
    final fileName = basename(event.path);
    if (fileName.startsWith('.')) return;

    if (event is FileSystemCreateEvent) {
      await _backupFile(File(event.path), vaultDir);
      onMediaUpdate();
    } else if (event is FileSystemDeleteEvent) {
      await DBHelper.instance.markMediaDeleted(fileName);
      onMediaUpdate();
    }
  }

  Future<void> _backupFile(File sourceFile, Directory vaultDir) async {
    try {
      if (!await sourceFile.exists()) return;

      // Wait briefly if file is currently being written by WhatsApp
      int retries = 0;
      while (await sourceFile.length() == 0 && retries < 5) {
        await Future.delayed(const Duration(milliseconds: 200));
        retries++;
      }

      if (await sourceFile.length() == 0) return; // Ignore incomplete 0-byte files

      final fileName = basename(sourceFile.path);
      final destPath = join(vaultDir.path, fileName);
      final destFile = File(destPath);

      if (!await destFile.exists()) {
        await sourceFile.copy(destPath);
        final mediaType = fileName.toLowerCase().endsWith('.mp4') ? 'video' : 'image';
        await DBHelper.instance.insertMedia(
          fileName: fileName,
          savedPath: destPath,
          mediaType: mediaType,
        );
      }
    } catch (e) {
      debugPrint("Media backup failed: $e");
    }
  }

  Future<void> _scanExistingMedia(Directory vaultDir, VoidCallback onMediaUpdate) async {
    for (final p in _whatsappPaths) {
      final dir = Directory(p);
      if (await dir.exists()) {
        try {
          final entities = dir.listSync();
          for (final entity in entities) {
            if (entity is File && !basename(entity.path).startsWith('.')) {
              await _backupFile(entity, vaultDir);
            }
          }
        } catch (_) {}
      }
    }

    // Check if any tracked media in vault has been deleted from WhatsApp directory
    try {
      final recorded = await DBHelper.instance.fetchMedia();
      for (final item in recorded) {
        if (item['is_deleted_by_sender'] == 0) {
          final fileName = item['file_name'] as String;
          bool stillExistsInWhatsApp = false;
          for (final p in _whatsappPaths) {
            if (File(join(p, fileName)).existsSync()) {
              stillExistsInWhatsApp = true;
              break;
            }
          }
          if (!stillExistsInWhatsApp) {
            await DBHelper.instance.markMediaDeleted(fileName);
          }
        }
      }
    } catch (_) {}

    onMediaUpdate();
  }

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

  void stopWatching() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _pollingTimer?.cancel();
    _isWatching = false;
  }
}

