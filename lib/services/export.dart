import 'dart:convert';

import '../models/log_entry.dart';
import 'usage_snapshots.dart';

/// Export v2 (E2, FR30, thesis 3.8): the participant's data for analysis.
///
/// Contains the saved day-by-day and hourly screen time, every log and (from
/// D3) nudge events. It never contains the display name, the chat or any API
/// key. Its schema_version is the export format, separate from the
/// version of second_brain.json.
const exportSchemaVersion = 2;

Map<String, dynamic> buildExport({
  required DateTime now,
  required String appVersion,
  required List<DaySnapshot> daily,
  required List<HourUsage> hourly,
  required List<LogEntry> logs,
  List<Map<String, dynamic>> nudges = const [],
}) {
  final days = [...daily]..sort((a, b) => a.date.compareTo(b.date));
  final hours = [...hourly]
    ..sort((a, b) => a.date != b.date
        ? a.date.compareTo(b.date)
        : a.hour != b.hour
            ? a.hour.compareTo(b.hour)
            : a.category.compareTo(b.category));
  final entries = [...logs]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return {
    'schema_version': exportSchemaVersion,
    'exported_at': toOffsetIso(now),
    'app_version': appVersion,
    'daily': days.map((d) => d.toJson()).toList(),
    'hourly': hours.map((h) => h.toJson()).toList(),
    'logs': entries.map((l) => l.toJson()).toList(),
    'nudges': nudges,
  };
}

String encodeExport(Map<String, dynamic> export) =>
    const JsonEncoder.withIndent('  ').convert(export);

/// e.g. `anchor_export_2026-11-21.json`: date only, no name.
String exportFileName(DateTime now) => 'anchor_export_${dateKey(now)}.json';
