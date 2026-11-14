import 'package:flutter_test/flutter_test.dart';
import 'package:wa_shield/capture_bridge.dart';

void main() {
  group('decodeCaptureEvent', () {
    test('decodes a message event', () {
      final e = decodeCaptureEvent(
          '{"type":"msg","uid":"abc","pkg":"com.whatsapp","chatKey":"com.whatsapp|t:alice",'
          '"chatTitle":"Alice","isGroup":false,"sender":"Alice","text":"hi","ts":1000}');
      expect(e, isNotNull);
      expect(e!['type'], 'msg');
      expect(e['uid'], 'abc');
      expect(e['ts'], 1000);
    });

    test('rejects malformed input', () {
      expect(decodeCaptureEvent(null), isNull);
      expect(decodeCaptureEvent(''), isNull);
      expect(decodeCaptureEvent('not json'), isNull);
      expect(decodeCaptureEvent('[1,2]'), isNull);
      expect(decodeCaptureEvent('{"uid":"x"}'), isNull); // no type
      expect(decodeCaptureEvent(42), isNull);
    });
  });
}
