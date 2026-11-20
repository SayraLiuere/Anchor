/// Timestamps with their time zone (A3, thesis 3.3.4).
///
/// Everything saved to `second_brain.json` is written as local time with its
/// UTC offset, e.g. `2026-11-16T12:18:01+08:00`, so exported data says both
/// the wall-clock time the user saw and the exact instant.
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// Local time with offset. Milliseconds are kept only when non-zero.
String toOffsetIso(DateTime t) {
  final l = t.toLocal();
  final o = l.timeZoneOffset;
  final m = o.inMinutes.abs();
  final ms = l.millisecond == 0 ? '' : '.${l.millisecond.toString().padLeft(3, '0')}';
  return '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}'
      'T${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}$ms'
      '${o.isNegative ? '-' : '+'}${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// Reads both forms. A value with an offset (or `Z`) is converted to the
/// phone's local time; an old value without one is taken as local time.
DateTime parseTimestamp(String s) {
  final t = DateTime.parse(s);
  return t.isUtc ? t.toLocal() : t;
}
