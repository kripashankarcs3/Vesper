import 'package:flutter_test/flutter_test.dart';
import 'package:wa_shield/status_saver.dart';

StatusFileEntry entry(
  String name, {
  int size = 1024,
  DateTime? modified,
  String pkg = 'com.whatsapp',
}) {
  return StatusFileEntry(
    path: '/storage/emulated/0/WhatsApp/Media/.Statuses/$name',
    name: name,
    size: size,
    modified: modified ?? DateTime(2026, 11, 1, 12),
    sourcePackage: pkg,
  );
}

void main() {
  group('filterAndSortStatusEntries', () {
    test('keeps supported image and video extensions (case-insensitive)', () {
      final names = [
        'a.jpg', 'b.jpeg', 'c.png', 'd.webp', 'e.JPG',
        'f.mp4', 'g.3gp', 'h.mkv', 'i.webm', 'j.MP4',
      ];
      final result = filterAndSortStatusEntries(names.map((n) => entry(n)));
      expect(result.map((s) => s.fileName).toSet(), names.toSet());
    });

    test('drops unsupported extensions', () {
      final result = filterAndSortStatusEntries([
        entry('note.txt'),
        entry('voice.opus'),
        entry('anim.gif'),
        entry('noext'),
        entry('ok.jpg'),
      ]);
      expect(result.map((s) => s.fileName), ['ok.jpg']);
    });

    test('drops .nomedia', () {
      final result = filterAndSortStatusEntries([entry('.nomedia', size: 0), entry('.nomedia')]);
      expect(result, isEmpty);
    });

    test('drops 0-byte files', () {
      final result = filterAndSortStatusEntries([
        entry('empty.jpg', size: 0),
        entry('empty.mp4', size: 0),
        entry('full.jpg', size: 10),
      ]);
      expect(result.map((s) => s.fileName), ['full.jpg']);
    });

    test('drops hidden and temp files', () {
      final result = filterAndSortStatusEntries([
        entry('.hidden.jpg'),
        entry('.trashed-123-x.mp4'),
        entry('~tmp.jpg'),
        entry('download.jpg.tmp'),
        entry('video.mp4.part'),
        entry('visible.jpg'),
      ]);
      expect(result.map((s) => s.fileName), ['visible.jpg']);
    });

    test('sorts newest first, ties broken by name', () {
      final result = filterAndSortStatusEntries([
        entry('old.jpg', modified: DateTime(2026, 11, 1, 8)),
        entry('new.mp4', modified: DateTime(2026, 11, 1, 20)),
        entry('mid_b.jpg', modified: DateTime(2026, 11, 1, 12)),
        entry('mid_a.jpg', modified: DateTime(2026, 11, 1, 12)),
      ]);
      expect(result.map((s) => s.fileName), ['new.mp4', 'mid_a.jpg', 'mid_b.jpg', 'old.jpg']);
    });

    test('assigns image/video type and keeps source package and path', () {
      final result = filterAndSortStatusEntries([
        entry('pic.webp', modified: DateTime(2026, 11, 2)),
        entry('clip.3gp', pkg: 'com.whatsapp.w4b', modified: DateTime(2026, 11, 1)),
      ]);
      expect(result[0].type, StatusMediaType.image);
      expect(result[0].isVideo, isFalse);
      expect(result[1].type, StatusMediaType.video);
      expect(result[1].isVideo, isTrue);
      expect(result[1].sourcePackage, 'com.whatsapp.w4b');
      expect(result[1].path, endsWith('/clip.3gp'));
    });

    test('collapses duplicate file names, keeping the newest copy', () {
      final result = filterAndSortStatusEntries([
        entry('same.jpg', modified: DateTime(2026, 11, 1), pkg: 'com.whatsapp'),
        entry('same.jpg', modified: DateTime(2026, 11, 3), pkg: 'com.whatsapp.w4b'),
      ]);
      expect(result, hasLength(1));
      expect(result.single.sourcePackage, 'com.whatsapp.w4b');
    });

    test('empty input gives empty output', () {
      expect(filterAndSortStatusEntries(const []), isEmpty);
    });
  });

  test('statusTypeForFileName', () {
    expect(statusTypeForFileName('x.JPEG'), StatusMediaType.image);
    expect(statusTypeForFileName('x.webm'), StatusMediaType.video);
    expect(statusTypeForFileName('x.pdf'), isNull);
  });
}
