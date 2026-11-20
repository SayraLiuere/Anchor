import 'package:intl/intl.dart';

import 'screen_time.dart';
import 'usage_snapshots.dart';

/// Personal baseline (C2, FR19, thesis 3.5.8): what a usual day looks like
/// for this user, from their own saved days.

/// Categories compared. `screen` is screen time without music and podcasts.
const baselineCategories = ['screen', 'social', 'video', 'games'];

String baselineLabel(String c) => switch (c) {
      'screen' => 'Screen time',
      'social' => 'Social media',
      'video' => 'Videos',
      'games' => 'Games',
      _ => c,
    };

/// NudgeSettings limit key for each category.
const limitKeyFor = {'screen': 'total', 'social': 'social', 'video': 'video', 'games': 'games'};

double median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

double _minutesIn(String category, String group) =>
    category == 'screen' ? (group == 'audio' ? 0 : 1) : (group == category ? 1 : 0);

/// How today compares with the usual for this weekday, up to the same time.
class Deviation {
  Deviation(this.category, this.today, this.usual, this.weekday, {required this.byWeekday});

  final String category;
  final double today, usual;
  final int weekday;

  /// True when the usual comes from this weekday (2+ samples), false when
  /// it falls back to the median of all days.
  final bool byWeekday;

  double get difference => today - usual;

  /// Percent above (positive) or below the usual; null when the usual is
  /// under 5 minutes, where a percentage means little.
  double? get percent => usual < 5 ? null : difference / usual * 100;

  /// "your usual Monday" or "your usual day".
  String get usualPhrase => byWeekday
      ? 'your usual ${DateFormat('EEEE').format(DateTime(2026, 11, 15 + weekday))}'
      : 'your usual day';
}

class Baseline {
  Baseline._(this.days, this._hours);

  /// Days needed before a baseline is shown (spec: 7 or more).
  static const minDays = 7;

  /// Same-weekday samples needed; fewer means the overall median is used.
  static const minWeekdaySamples = 2;

  final List<DaySnapshot> days;
  final Map<String, List<HourUsage>> _hours;

  /// Null until there are [minDays] saved days.
  static Baseline? from(List<DaySnapshot> days, List<HourUsage> hourly) {
    if (days.length < minDays) return null;
    final byDate = <String, List<HourUsage>>{};
    for (final h in hourly) {
      byDate.putIfAbsent(h.date, () => []).add(h);
    }
    return Baseline._(days, byDate);
  }

  int _weekday(DaySnapshot d) => DateTime.parse(d.date).weekday;

  double _dayMinutes(DaySnapshot d, String c) =>
      c == 'screen' ? d.totalMinutes - d.group('audio') : d.group(c);

  /// Minutes of [c] on day [d] before [minuteOfDay]; the current hour counts
  /// in proportion. Falls back to the full day when hourly rows are missing.
  double _minutesBy(DaySnapshot d, String c, int minuteOfDay) {
    final hours = _hours[d.date];
    if (hours == null) return _dayMinutes(d, c);
    final h = minuteOfDay ~/ 60, part = (minuteOfDay % 60) / 60;
    var total = 0.0;
    for (final r in hours) {
      final w = _minutesIn(c, r.category);
      if (w == 0) continue;
      if (r.hour < h) total += r.minutes;
      if (r.hour == h) total += r.minutes * part;
    }
    return total;
  }

  (double, bool) _usual(List<double> Function(Iterable<DaySnapshot>) values, int weekday) {
    final same = days.where((d) => _weekday(d) == weekday);
    if (same.length >= minWeekdaySamples) return (median(values(same)), true);
    return (median(values(days)), false);
  }

  /// Usual full-day minutes of [c] on [weekday].
  double usualDay(String c, int weekday) =>
      _usual((ds) => [for (final d in ds) _dayMinutes(d, c)], weekday).$1;

  /// Usual minutes of [c] by [minuteOfDay] on [weekday], and whether that
  /// came from the same weekday.
  (double, bool) usualBy(String c, int weekday, int minuteOfDay) =>
      _usual((ds) => [for (final d in ds) _minutesBy(d, c, minuteOfDay)], weekday);

  /// Today so far against the usual by the same time, for every category.
  List<Deviation> compareToday(UsageSummary today, DateTime now) {
    final minute = now.hour * 60 + now.minute;
    double todayMinutes(String c) => switch (c) {
          'screen' => today.screenMinutes,
          'social' => today.socialMinutes,
          'video' => today.videoMinutes,
          _ => today.gamesMinutes,
        };
    return [
      for (final c in baselineCategories)
        () {
          final (usual, byWeekday) = usualBy(c, now.weekday, minute);
          return Deviation(c, todayMinutes(c), usual, now.weekday, byWeekday: byWeekday);
        }(),
    ];
  }

  /// Suggested daily limit per category: the median day minus 10%, rounded
  /// to 5 minutes. Categories with a median under 10 minutes get none.
  Map<String, int> suggestedLimits() => {
        for (final c in baselineCategories)
          if (median([for (final d in days) _dayMinutes(d, c)]) >= 10)
            limitKeyFor[c]!:
                ((median([for (final d in days) _dayMinutes(d, c)]) * 0.9) / 5).round() * 5,
      };
}

/// The deviation worth a Home card: the largest rise of at least 25% and
/// 15 minutes. Null when today looks usual.
Deviation? headlineDeviation(List<Deviation> ds) {
  final up = ds
      .where((d) => (d.percent ?? 0) >= 25 && d.difference >= 15)
      .toList()
    ..sort((a, b) => b.percent!.compareTo(a.percent!));
  return up.firstOrNull;
}

/// Large deviations become risk reasons (C2): at least 50% and 30 minutes
/// above the usual by this time.
List<String> deviationReasons(List<Deviation> ds) => [
      for (final d in ds)
        if ((d.percent ?? 0) >= 50 && d.difference >= 30)
          '${baselineLabel(d.category)} ${d.percent!.round()}% above ${d.usualPhrase} so far',
    ];
