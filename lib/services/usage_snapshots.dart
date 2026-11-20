import 'package:intl/intl.dart';

import 'screen_time.dart';

/// Daily and hourly usage snapshots (A2, FR25, thesis 3.3.4).
///
/// Android only keeps detailed usage events for about a week, so each complete
/// day is saved once into `second_brain.json` and never overwritten. The
/// stored history feeds the risk features now and the baseline (C2) and
/// time-risk grid (D1) later.

/// App groups stored per day and hour. `audio` stays 0 until A5.
const snapshotGroups = ['social', 'video', 'games', 'audio', 'chat', 'other'];

/// Hours counted as late night: 23:00–05:00 (same as `LogEntry.isLateNight`).
bool isLateNightHour(int h) => h >= 23 || h < 5;

final _dateFormat = DateFormat('yyyy-MM-dd');
String dateKey(DateTime d) => _dateFormat.format(d);
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

double _r2(double x) => (x * 100).roundToDouble() / 100;
double _num(Object? v) => (v as num?)?.toDouble() ?? 0;

/// One foreground session as read from Android: group and times only.
class RawSession {
  RawSession(this.group, this.start, this.end);

  RawSession.fromMap(Map<dynamic, dynamic> m)
      : group = m['group'] as String? ?? 'other',
        start = DateTime.fromMillisecondsSinceEpoch(m['start'] as int),
        end = DateTime.fromMillisecondsSinceEpoch(m['end'] as int);

  final String group;
  final DateTime start, end;
}

/// One complete day, stored in `usage_daily`.
class DaySnapshot {
  DaySnapshot({
    required this.date,
    required this.minutes,
    required this.unlocks,
    required this.opens,
    required this.lateNightMinutes,
  });

  /// Local calendar date, `yyyy-MM-dd`.
  final String date;

  /// Minutes per group in [snapshotGroups].
  final Map<String, double> minutes;
  final int unlocks;

  /// App opens (sessions started that day). Not in the spec's row, but the
  /// Random Forest uses it as `app_opens_per_day`.
  final int opens;
  final double lateNightMinutes;

  double get totalMinutes => minutes.values.fold(0.0, (a, b) => a + b);
  double group(String g) => minutes[g] ?? 0;

  Map<String, dynamic> toJson() => {
        'date': date,
        'total_min': _r2(totalMinutes),
        for (final g in snapshotGroups) '${g}_min': _r2(group(g)),
        'unlocks': unlocks,
        'late_night_min': _r2(lateNightMinutes),
        'opens': opens,
      };

  /// Missing fields default to 0, so rows from older versions still load.
  factory DaySnapshot.fromJson(Map<String, dynamic> j) => DaySnapshot(
        date: j['date'] as String,
        minutes: {for (final g in snapshotGroups) g: _num(j['${g}_min'])},
        unlocks: (j['unlocks'] as num?)?.toInt() ?? 0,
        opens: (j['opens'] as num?)?.toInt() ?? 0,
        lateNightMinutes: _num(j['late_night_min']),
      );

  /// Same shape as a live day read, so features and charts treat both alike.
  UsageSummary toSummary() => UsageSummary.fromMap({
        'totalMinutes': totalMinutes,
        'socialMinutes': group('social'),
        'videoMinutes': group('video'),
        'gamesMinutes': group('games'),
        'chatMinutes': group('chat'),
        'unlocks': unlocks,
        'opens': opens,
        'lateNightMinutes': lateNightMinutes,
        'longestSessionMinutes': 0.0,
        'longestSessionApp': null,
        'dayStart': DateTime.parse(date).millisecondsSinceEpoch,
        'apps': const [],
      });
}

/// Minutes of one group in one clock hour, stored in `usage_hourly`.
class HourUsage {
  HourUsage(this.date, this.hour, this.category, this.minutes);

  factory HourUsage.fromJson(Map<String, dynamic> j) => HourUsage(
        j['date'] as String,
        (j['hour'] as num).toInt(),
        j['category'] as String,
        _num(j['minutes']),
      );

  final String date;
  final int hour;
  final String category;
  final double minutes;

  Map<String, dynamic> toJson() =>
      {'date': date, 'hour': hour, 'category': category, 'minutes': _r2(minutes)};
}

/// Splits [sessions] at every clock hour (and so at midnight) and adds them up
/// per day, hour and group. Only days in [dates] are returned, so a read can
/// start before the first day to catch a session running past midnight.
/// Hourly rows are non-zero only.
({List<DaySnapshot> days, List<HourUsage> hours}) buildSnapshots(
  List<RawSession> sessions,
  List<DateTime> unlocks,
  Iterable<String> dates,
) {
  final wanted = dates.toSet();
  // date -> hour -> group -> minutes
  final buckets = <String, Map<int, Map<String, double>>>{};
  final opens = <String, int>{};

  for (final s in sessions) {
    final group = snapshotGroups.contains(s.group) ? s.group : 'other';
    final startKey = dateKey(s.start);
    if (wanted.contains(startKey)) opens[startKey] = (opens[startKey] ?? 0) + 1;

    var t = s.start;
    while (t.isBefore(s.end)) {
      // DateTime normalises hour 24 to the next day's midnight.
      final nextHour = DateTime(t.year, t.month, t.day, t.hour + 1);
      final until = nextHour.isBefore(s.end) ? nextHour : s.end;
      final key = dateKey(t);
      if (wanted.contains(key)) {
        final g = buckets.putIfAbsent(key, () => {}).putIfAbsent(t.hour, () => {});
        g[group] = (g[group] ?? 0) + until.difference(t).inMilliseconds / 60000;
      }
      t = until;
    }
  }

  final unlockCount = <String, int>{};
  for (final u in unlocks) {
    final k = dateKey(u);
    if (wanted.contains(k)) unlockCount[k] = (unlockCount[k] ?? 0) + 1;
  }

  final days = <DaySnapshot>[];
  final hours = <HourUsage>[];
  for (final date in wanted.toList()..sort()) {
    final perHour = buckets[date] ?? {};
    final minutes = {for (final g in snapshotGroups) g: 0.0};
    var late = 0.0;
    for (final h in perHour.keys.toList()..sort()) {
      for (final e in perHour[h]!.entries) {
        if (e.value <= 0) continue;
        minutes[e.key] = minutes[e.key]! + e.value;
        if (isLateNightHour(h)) late += e.value;
        hours.add(HourUsage(date, h, e.key, e.value));
      }
    }
    days.add(DaySnapshot(
      date: date,
      minutes: minutes,
      unlocks: unlockCount[date] ?? 0,
      opens: opens[date] ?? 0,
      lateNightMinutes: late,
    ));
  }
  return (days: days, hours: hours);
}

/// Complete days among the last [n] (yesterday back) with no stored row,
/// oldest first.
List<String> missingDays(Iterable<String> stored, DateTime now, {int n = 7}) {
  final have = stored.toSet();
  final today = dayOf(now);
  return [
    for (var d = n; d >= 1; d--)
      dateKey(DateTime(today.year, today.month, today.day - d)),
  ].where((k) => !have.contains(k)).toList();
}

/// The 7-day window used for features and the week chart: stored rows for
/// the last 6 complete days, then today's live read. Oldest first.
/// Days with no stored row are left out rather than counted as zero.
List<UsageSummary> weekFromSnapshots(
    List<DaySnapshot> stored, UsageSummary? today, DateTime now) {
  final byDate = {for (final s in stored) s.date: s};
  final t = dayOf(now);
  return [
    for (var d = 6; d >= 1; d--)
      if (byDate[dateKey(DateTime(t.year, t.month, t.day - d))] case final s?)
        s.toSummary(),
    if (today != null) today,
  ];
}
