import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

final _offsetForm = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{3})?[+-]\d\d:\d\d$');

String _offsetOf(DateTime t) {
  final o = t.timeZoneOffset;
  final m = o.inMinutes.abs();
  return '${o.isNegative ? '-' : '+'}'
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

void main() {
  test('local time is written with its offset and round-trips', () {
    final t = DateTime(2026, 11, 16, 12, 18, 1);
    final s = toOffsetIso(t);
    expect(s, matches(_offsetForm));
    expect(s, startsWith('2026-11-16T12:18:01'));
    expect(s, endsWith(_offsetOf(t)));
    final back = parseTimestamp(s);
    expect(back, t); // same instant
    expect(back.isUtc, isFalse); // and back in local time
    expect(back.hour, 12);
  });

  test('milliseconds are kept, and a UTC input is written as local', () {
    final t = DateTime(2026, 11, 16, 23, 5, 9, 42);
    expect(toOffsetIso(t), contains('23:05:09.042'));
    expect(parseTimestamp(toOffsetIso(t)), t);
    expect(parseTimestamp(toOffsetIso(t.toUtc())), t);
  });

  test('an offset string means that exact instant', () {
    final instant = DateTime.utc(2026, 11, 16, 4, 18, 1);
    for (final s in ['2026-11-16T12:18:01+08:00', '2026-11-16T04:18:01Z']) {
      final t = parseTimestamp(s);
      expect(t.isAtSameMomentAs(instant), isTrue, reason: s);
      expect(t.isUtc, isFalse, reason: s);
    }
  });

  test('an old value without offset is taken as local time', () {
    final t = parseTimestamp('2026-11-16T12:18:01.123456');
    expect(t.isUtc, isFalse);
    expect(t, DateTime(2026, 11, 16, 12, 18, 1, 123, 456));
  });

  test('a pre-A3 file still loads, and saves again with offsets', () {
    // Shapes as written by the app before A3 (toIso8601String, no offset).
    final old = jsonDecode('''{
      "logs": [{"id": "1", "timestamp": "2026-11-10T23:30:00.000",
        "kind": "episode", "mood_rating": 2, "perceived_stress": 4,
        "craving_intensity": 3, "trigger_category": ["lateNight"],
        "perceived_duration": 40, "continued_or_resisted": "continued",
        "context_note": "", "synthetic": false}],
      "chat": [{"fromUser": true, "text": "hi", "at": "2026-11-10T23:31:12.345678"}],
      "usage_daily": [{"date": "2026-11-09", "total_min": 30, "social_min": 30,
        "video_min": 0, "games_min": 0, "audio_min": 0, "chat_min": 0,
        "other_min": 0, "unlocks": 5, "late_night_min": 0, "opens": 3}]
    }''') as Map<String, dynamic>;

    final log = LogEntry.fromJson((old['logs'] as List).first as Map<String, dynamic>);
    expect(log.timestamp, DateTime(2026, 11, 10, 23, 30));
    expect(log.isLateNight, isTrue);
    final saved = log.toJson()['timestamp'] as String;
    expect(saved, matches(_offsetForm));
    expect(LogEntry.fromJson(log.toJson()).timestamp, log.timestamp);

    final msg = ChatMessage.fromJson((old['chat'] as List).first as Map<String, dynamic>);
    expect(msg.at, DateTime(2026, 11, 10, 23, 31, 12, 345, 678));
    expect(msg.toJson()['at'], matches(_offsetForm));

    final day = DaySnapshot.fromJson((old['usage_daily'] as List).first as Map<String, dynamic>);
    expect(day.dayStart, isNull);
    expect(day.toJson().containsKey('day_start'), isFalse); // nothing invented
  });

  test('new day rows record local midnight with its offset', () {
    final r = buildSnapshots(
        [RawSession('social', DateTime(2026, 11, 17, 9), DateTime(2026, 11, 17, 10))],
        [], ['2026-11-17']);
    final j = r.days.single.toJson();
    expect(j['day_start'], toOffsetIso(DateTime(2026, 11, 17)));
    expect(j['day_start'], startsWith('2026-11-17T00:00:00'));
    expect(DaySnapshot.fromJson(j).dayStart, j['day_start']); // kept as written
  });
}
