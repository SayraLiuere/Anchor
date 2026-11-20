import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/export.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

void main() {
  final now = DateTime(2026, 11, 21, 9, 30);
  final snaps = buildSnapshots([
    RawSession('social', DateTime(2026, 11, 20, 23, 30), DateTime(2026, 11, 21, 0, 10)),
    RawSession('video', DateTime(2026, 11, 19, 20, 0), DateTime(2026, 11, 19, 20, 45)),
  ], [DateTime(2026, 11, 20, 8)], ['2026-11-20', '2026-11-19']);
  final logs = [
    LogEntry(id: 'b', timestamp: DateTime(2026, 11, 20, 23, 50), kind: EntryKind.episode,
        mood: 2, stress: 3, craving: 4, durationMinutes: 40, note: 'my own note'),
    LogEntry(id: 'a', timestamp: DateTime(2026, 11, 19, 8), kind: EntryKind.checkIn,
        mood: 4, stress: 2, craving: 1),
  ];

  Map<String, dynamic> export() => jsonDecode(encodeExport(buildExport(
        now: now,
        appVersion: '1.0.0+1',
        daily: snaps.days.reversed.toList(),
        hourly: snaps.hours.reversed.toList(),
        logs: logs,
      ))) as Map<String, dynamic>;

  test('export v2 has exactly the spec keys', () {
    final e = export();
    expect(e.keys.toSet(), {
      'schema_version', 'exported_at', 'app_version',
      'daily', 'hourly', 'logs', 'nudges',
    });
    expect(e['schema_version'], 2);
    expect(e['app_version'], '1.0.0+1');
    expect(e['nudges'], isEmpty);
  });

  test('exported_at carries the offset and means the export time', () {
    final at = export()['exported_at'] as String;
    expect(at, matches(RegExp(r'[+-]\d\d:\d\d$')));
    expect(parseTimestamp(at), now);
  });

  test('history is complete and sorted oldest first', () {
    final e = export();
    expect((e['daily'] as List).map((d) => d['date']), ['2026-11-19', '2026-11-20']);
    expect((e['daily'] as List).last['social_min'], 30);
    expect((e['daily'] as List).last['unlocks'], 1);
    final hourly = (e['hourly'] as List).cast<Map<String, dynamic>>();
    expect(hourly.map((h) => '${h['date']} ${h['hour']}'),
        ['2026-11-19 20', '2026-11-20 23']);
    expect((e['logs'] as List).map((l) => l['id']), ['a', 'b']);
    // Logs read back as the same entries.
    final back = LogEntry.fromJson((e['logs'] as List).last as Map<String, dynamic>);
    expect(back.timestamp, logs.first.timestamp);
    expect(back.note, 'my own note');
  });

  test('no display name, chat or API key in the export', () {
    final text = encodeExport(buildExport(
        now: now, appVersion: 'x', daily: snaps.days, hourly: snaps.hours, logs: logs));
    for (final key in ['displayName', 'apiKey', 'chat', 'provider', 'model']) {
      expect(text, isNot(contains('"$key"')), reason: key);
    }
  });

  test('file name holds only the date', () {
    expect(exportFileName(now), 'anchor_export_2026-11-21.json');
  });
}
