import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db_helper.dart';

enum StatusMediaType { image, video }

StatusMediaType statusMediaTypeFromString(String s) =>
    s == 'video' ? StatusMediaType.video : StatusMediaType.image;

/// A plain directory entry (no filesystem access needed). Used as the input to
/// the pure [filterAndSortStatusEntries] function so it can be unit tested.
@immutable
class StatusFileEntry {
  final String path;
  final String name;
  final int size;
  final DateTime modified;
  final String sourcePackage;

  const StatusFileEntry({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.sourcePackage,
  });
}

/// A status currently present in WhatsApp's .Statuses folder.
@immutable
class LiveStatus {
  final String path;
  final String fileName;
  final StatusMediaType type;
  final DateTime modified;
  final String sourcePackage;

  const LiveStatus({
    required this.path,
    required this.fileName,
    required this.type,
    required this.modified,
    required this.sourcePackage,
  });

  bool get isVideo => type == StatusMediaType.video;
}

/// A status copied into the app-private status_vault.
@immutable
class SavedStatus {
  final int id;
  final String path;
  final String fileName;
  final StatusMediaType type;
  final String sourcePackage;
  final DateTime originalModified;
  final DateTime savedAt;

  /// False when the DB row exists but the vault file is gone.
  final bool fileExists;

  const SavedStatus({
    required this.id,
    required this.path,
    required this.fileName,
    required this.type,
    required this.sourcePackage,
    required this.originalModified,
    required this.savedAt,
    required this.fileExists,
  });

  bool get isVideo => type == StatusMediaType.video;
}

const Set<String> kStatusImageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};
const Set<String> kStatusVideoExtensions = {'.mp4', '.3gp', '.mkv', '.webm'};

/// Returns the media type for [fileName] by extension, or null if unsupported.
StatusMediaType? statusTypeForFileName(String fileName) {
  final ext = p.extension(fileName).toLowerCase();
  if (kStatusImageExtensions.contains(ext)) return StatusMediaType.image;
  if (kStatusVideoExtensions.contains(ext)) return StatusMediaType.video;
  return null;
}

/// PURE: filters raw directory entries down to real status media and sorts them
/// newest first. Skips `.nomedia`, hidden (dot-prefixed) and temp files,
/// 0-byte files and unsupported extensions. Duplicate file names (same status
/// visible via two paths) are collapsed, keeping the newest.
List<LiveStatus> filterAndSortStatusEntries(Iterable<StatusFileEntry> entries) {
  final byName = <String, LiveStatus>{};
  for (final e in entries) {
    final name = e.name;
    if (name.isEmpty) continue;
    if (name.startsWith('.')) continue; // .nomedia and hidden files
    if (name.startsWith('~')) continue; // temp
    final lower = name.toLowerCase();
    if (lower.endsWith('.tmp') || lower.endsWith('.part') || lower.endsWith('.crdownload')) {
      continue;
    }
    if (e.size <= 0) continue;
    final type = statusTypeForFileName(name);
    if (type == null) continue;

    final item = LiveStatus(
      path: e.path,
      fileName: name,
      type: type,
      modified: e.modified,
      sourcePackage: e.sourcePackage,
    );
    final existing = byName[name];
    if (existing == null || item.modified.isAfter(existing.modified)) {
      byName[name] = item;
    }
  }
  final list = byName.values.toList()
    ..sort((a, b) {
      final c = b.modified.compareTo(a.modified);
      return c != 0 ? c : a.fileName.compareTo(b.fileName);
    });
  return list;
}

/// Result of a live scan: the statuses plus any directories that could not be read.
class LiveStatusScan {
  final List<LiveStatus> statuses;
  final List<String> unreadableDirs;
  const LiveStatusScan(this.statuses, this.unreadableDirs);
}

class StatusSaverService {
  static final StatusSaverService _instance = StatusSaverService._internal();
  factory StatusSaverService() => _instance;
  StatusSaverService._internal();

  static const MethodChannel _scannerChannel = MethodChannel('wa_shield/media_scanner');

  static const String exportDirPath = '/storage/emulated/0/Pictures/WA Shield Status';

  /// (directory, source package) pairs that may hold WhatsApp statuses.
  static const List<(String, String)> statusSources = [
    ('/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/.Statuses', 'com.whatsapp'),
    ('/storage/emulated/0/WhatsApp/Media/.Statuses', 'com.whatsapp'),
    (
      '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/.Statuses',
      'com.whatsapp.w4b'
    ),
    ('/storage/emulated/0/WhatsApp Business/Media/.Statuses', 'com.whatsapp.w4b'),
  ];

  Future<Directory> _vaultDir({bool create = true}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'status_vault'));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Lists statuses currently on disk, newest first. Never throws for a single
  /// unreadable directory; those are reported in [LiveStatusScan.unreadableDirs].
  Future<LiveStatusScan> scanLiveStatuses() async {
    final entries = <StatusFileEntry>[];
    final unreadable = <String>[];
    for (final (dirPath, pkg) in statusSources) {
      final dir = Directory(dirPath);
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          try {
            final stat = await entity.stat();
            entries.add(StatusFileEntry(
              path: entity.path,
              name: p.basename(entity.path),
              size: stat.size,
              modified: stat.modified,
              sourcePackage: pkg,
            ));
          } catch (e) {
            debugPrint('StatusSaver: cannot stat ${entity.path}: $e');
          }
        }
      } catch (e) {
        debugPrint('StatusSaver: cannot read $dirPath: $e');
        unreadable.add(dirPath);
      }
    }
    return LiveStatusScan(filterAndSortStatusEntries(entries), unreadable);
  }

  Future<List<LiveStatus>> listLiveStatuses() async => (await scanLiveStatuses()).statuses;

  Future<Set<String>> savedFileNames() => DBHelper.instance.fetchSavedStatusFileNames();

  /// Copies [status] into the app-private vault and records it. Returns true if
  /// it was newly saved, false if it was already saved. Throws on copy/DB failure.
  Future<bool> saveToVault(LiveStatus status) async {
    if (await DBHelper.instance.isStatusSaved(status.fileName)) return false;

    final source = File(status.path);
    if (!await source.exists()) {
      throw FileSystemException('Status file no longer exists', status.path);
    }
    final vault = await _vaultDir();
    final destPath = p.join(vault.path, status.fileName);
    // A same-named file without a DB row is an orphan from an earlier failed
    // save; overwriting it is safe.
    await source.copy(destPath);

    try {
      await DBHelper.instance.insertSavedStatus(
        fileName: status.fileName,
        savedPath: destPath,
        mediaType: status.isVideo ? 'video' : 'image',
        sourcePkg: status.sourcePackage,
        originalMtime: status.modified.millisecondsSinceEpoch,
      );
    } catch (e) {
      // Don't leave an untracked copy behind if the row could not be written.
      try {
        await File(destPath).delete();
      } catch (_) {}
      rethrow;
    }
    return true;
  }

  /// Saves every status in [statuses]; returns how many were newly saved.
  /// Individual failures are skipped (logged) so one bad file does not abort.
  Future<int> saveAll(List<LiveStatus> statuses) async {
    int saved = 0;
    for (final s in statuses) {
      try {
        if (await saveToVault(s)) saved++;
      } catch (e) {
        debugPrint('StatusSaver: save failed for ${s.fileName}: $e');
      }
    }
    return saved;
  }

  /// Saved statuses, newest saved first. Rows whose file is missing are kept
  /// but flagged via [SavedStatus.fileExists] so the user can delete them.
  Future<List<SavedStatus>> listSaved() async {
    final rows = await DBHelper.instance.fetchSavedStatuses();
    return rows.map((r) {
      final path = r['saved_path'] as String;
      return SavedStatus(
        id: r['id'] as int,
        path: path,
        fileName: r['file_name'] as String,
        type: statusMediaTypeFromString(r['media_type'] as String),
        sourcePackage: r['source_pkg'] as String,
        originalModified: DateTime.fromMillisecondsSinceEpoch(r['original_mtime'] as int),
        savedAt: DateTime.fromMillisecondsSinceEpoch(r['saved_at'] as int),
        fileExists: File(path).existsSync(),
      );
    }).toList();
  }

  /// Deletes the vault file and its DB row. Returns false if the file could not
  /// be deleted (the row is then kept so nothing is silently orphaned).
  Future<bool> deleteSaved(int id) async {
    final row = await DBHelper.instance.fetchSavedStatusById(id);
    if (row == null) return true;
    final file = File(row['saved_path'] as String);
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('StatusSaver: delete failed for ${file.path}: $e');
      return false;
    }
    await DBHelper.instance.deleteSavedStatus(id);
    return true;
  }

  /// Explicit user action: copies [path] to public Pictures/WA Shield Status and
  /// asks the media scanner to index it. Returns true on success.
  Future<bool> exportToGallery(String path) async {
    try {
      final source = File(path);
      if (!await source.exists()) return false;
      final dir = Directory(exportDirPath);
      if (!await dir.exists()) await dir.create(recursive: true);

      final base = p.basenameWithoutExtension(path);
      final ext = p.extension(path);
      var destPath = p.join(dir.path, '$base$ext');
      final srcLen = await source.length();
      final existing = File(destPath);
      if (await existing.exists()) {
        if (await existing.length() == srcLen) {
          // Already exported; just make sure it's indexed.
          await _scan(destPath);
          return true;
        }
        int n = 1;
        while (await File(destPath).exists()) {
          destPath = p.join(dir.path, '${base}_$n$ext');
          n++;
        }
      }
      await source.copy(destPath);
      await _scan(destPath);
      return true;
    } catch (e) {
      debugPrint('StatusSaver: export failed for $path: $e');
      return false;
    }
  }

  Future<void> _scan(String path) async {
    try {
      await _scannerChannel.invokeMethod<bool>('scanFile', {'path': path});
    } catch (e) {
      // The file is exported regardless; it will appear after the next system scan.
      debugPrint('StatusSaver: media scan failed for $path: $e');
    }
  }

  /// Deletes EVERY file in status_vault, including orphans not in the DB.
  /// Returns true only if the directory ends up empty (or does not exist).
  Future<bool> deleteAllSavedStatusFiles() async {
    final dir = await _vaultDir(create: false);
    if (!await dir.exists()) return true;
    await for (final entity in dir.list()) {
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        debugPrint('Status wipe: failed to delete ${entity.path}: $e');
      }
    }
    return await dir.list().isEmpty;
  }
}
