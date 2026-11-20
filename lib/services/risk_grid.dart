import 'schedule_service.dart';
import 'usage_snapshots.dart';

/// Time-risk grid and pre-emptive nudge (D1, FR12-FR13, thesis 3.5.4-3.5.5).

/// The groups that count as problematic use (audio and chat do not).
const psuGroups = {'social', 'video', 'games'};

/// One weekday x hour slot that is usually heavy for this user.
class RiskSlot {
  RiskSlot(this.weekday, this.hour, this.meanMinutes);

  /// 1 = Monday ... 7 = Sunday.
  final int weekday;
  final int hour;
  final double meanMinutes;

  @override
  String toString() => 'RiskSlot($weekday, $hour, ${meanMinutes.toStringAsFixed(1)})';
}

class RiskGrid {
  RiskGrid._(this.means, this.flagged, this.days, this.threshold);

  /// Saved days looked at: the last 28 before today.
  static const windowDays = 28;

  /// Fewer saved days than this in the window: no grid yet.
  static const minDays = 14;

  /// A slot must average at least this many minutes to be flagged.
  static const minMinutes = 20.0;

  /// Mean social + video + games minutes per (weekday, hour), over the days
  /// of that weekday in the window. Only slots with any use are present.
  final Map<(int, int), double> means;

  /// Slots above the 75th percentile and at least [minMinutes].
  final List<RiskSlot> flagged;
  final int days;

  /// The 75th percentile of the non-zero slot means.
  final double threshold;

  /// Null until there are [minDays] saved days in the last [windowDays].
  static RiskGrid? compute(List<DaySnapshot> daily, List<HourUsage> hourly, DateTime now) {
    final today = dayOf(now);
    final from = DateTime(today.year, today.month, today.day - windowDays);
    final dates = {
      for (final d in daily)
        if (!DateTime.parse(d.date).isBefore(from) && DateTime.parse(d.date).isBefore(today)) d.date,
    };
    if (dates.length < minDays) return null;

    final perWeekday = <int, int>{};
    for (final d in dates) {
      final wd = DateTime.parse(d).weekday;
      perWeekday[wd] = (perWeekday[wd] ?? 0) + 1;
    }
    final sums = <(int, int), double>{};
    for (final h in hourly) {
      if (!dates.contains(h.date) || !psuGroups.contains(h.category)) continue;
      final key = (DateTime.parse(h.date).weekday, h.hour);
      sums[key] = (sums[key] ?? 0) + h.minutes;
    }
    final means = {for (final e in sums.entries) e.key: e.value / perWeekday[e.key.$1]!};
    final threshold = percentile([for (final v in means.values) if (v > 0) v], 0.75);
    final flagged = [
      for (final e in means.entries)
        if (e.value > threshold && e.value >= minMinutes) RiskSlot(e.key.$1, e.key.$2, e.value),
    ]..sort((a, b) => a.weekday != b.weekday ? a.weekday - b.weekday : a.hour - b.hour);
    return RiskGrid._(means, flagged, dates.length, threshold);
  }
}

/// Nearest-rank percentile ([p] in 0..1); 0 for an empty list.
double percentile(List<double> xs, double p) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final rank = (p * s.length).ceil().clamp(1, s.length);
  return s[rank - 1];
}

/// Start times of flagged slots in the next [days] days, oldest first.
List<DateTime> upcomingSlotStarts(RiskGrid g, DateTime now, {int days = 7}) {
  final today = dayOf(now);
  return [
    for (var d = 0; d <= days; d++)
      for (final s in g.flagged)
        if (DateTime(today.year, today.month, today.day + d).weekday == s.weekday)
          DateTime(today.year, today.month, today.day + d, s.hour),
  ].where((t) => t.isAfter(now)).toList()
    ..sort();
}

/// Quiet blocks (C1) from yesterday to [days] days ahead, as time ranges.
List<(DateTime, DateTime)> quietRanges(ScheduleService s, DateTime now, {int days = 7}) {
  final today = dayOf(now);
  return [
    for (var d = -1; d <= days; d++)
      for (final o in s.occurrencesOn(DateTime(today.year, today.month, today.day + d)))
        if (o.block.quiet) (o.start, o.end),
  ];
}

/// Whether the heads-up should fire now. The background worker applies the
/// same rule to the plan it is given: a flagged slot starts in 10-25 min,
/// the user is not in a quiet block, no nudge in the last hour, not muted.
bool headsUpDue({
  required DateTime now,
  required List<DateTime> slotStarts,
  required List<(DateTime, DateTime)> quiet,
  DateTime? lastNudge,
  bool enabled = true,
}) {
  if (!enabled) return false;
  final soon = slotStarts.any((t) {
    final m = t.difference(now).inSeconds / 60;
    return m >= 10 && m <= 25;
  });
  if (!soon) return false;
  if (quiet.any((q) => !now.isBefore(q.$1) && now.isBefore(q.$2))) return false;
  return lastNudge == null || now.difference(lastNudge).inMinutes >= 60;
}

/// What the worker gets: slot starts and quiet ranges as epoch milliseconds.
Map<String, dynamic> headsUpPlanJson(List<DateTime> slots, List<(DateTime, DateTime)> quiet) => {
      'slots': [for (final t in slots) t.millisecondsSinceEpoch],
      'quiet': [
        for (final q in quiet) [q.$1.millisecondsSinceEpoch, q.$2.millisecondsSinceEpoch],
      ],
    };
