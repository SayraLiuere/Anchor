import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/schedule_block.dart';
import 'package:psu_second_brain/services/risk_grid.dart';
import 'package:psu_second_brain/services/schedule_service.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

/// [n] days before 21 Nov 2026 (a Saturday). Every day: 10 min of video at
/// 13:00 and 15 min of chat at 14:00; Saturdays add 60 min of social at
/// 21:00; Fridays add 25 min of games at 22:00.
({List<DaySnapshot> days, List<HourUsage> hours}) history(int n) {
  final days = <DaySnapshot>[];
  final hours = <HourUsage>[];
  for (var i = 1; i <= n; i++) {
    final d = DateTime(2026, 11, 21 - i);
    final sessions = [
      RawSession('video', DateTime(d.year, d.month, d.day, 13), DateTime(d.year, d.month, d.day, 13, 10)),
      RawSession('chat', DateTime(d.year, d.month, d.day, 14), DateTime(d.year, d.month, d.day, 14, 15)),
      if (d.weekday == DateTime.saturday)
        RawSession('social', DateTime(d.year, d.month, d.day, 21), DateTime(d.year, d.month, d.day, 22)),
      if (d.weekday == DateTime.friday)
        RawSession('games', DateTime(d.year, d.month, d.day, 22), DateTime(d.year, d.month, d.day, 22, 25)),
    ];
    final r = buildSnapshots(sessions, [], [dateKey(d)]);
    days.addAll(r.days);
    hours.addAll(r.hours);
  }
  return (days: days, hours: hours);
}

final now = DateTime(2026, 11, 21, 12);

void main() {
  test('no grid before 14 saved days in the last 28', () {
    final h = history(13);
    expect(RiskGrid.compute(h.days, h.hours, now), isNull);
    final h14 = history(14);
    expect(RiskGrid.compute(h14.days, h14.hours, now), isNotNull);
  });

  test('mean per weekday x hour, PSU groups only', () {
    final h = history(28);
    final g = RiskGrid.compute(h.days, h.hours, now)!;
    expect(g.days, 28);
    expect(g.means[(DateTime.saturday, 21)], 60);
    expect(g.means[(DateTime.friday, 22)], 25);
    expect(g.means[(DateTime.monday, 13)], 10);
    expect(g.means.containsKey((DateTime.monday, 14)), isFalse); // chat is not PSU
  });

  test('slots above the 75th percentile with 20+ minutes are flagged', () {
    final h = history(28);
    final g = RiskGrid.compute(h.days, h.hours, now)!;
    // 7 slots of 10 min, Fri 22:00 at 25, Sat 21:00 at 60 -> p75 is 10.
    expect(g.threshold, 10);
    expect(g.flagged.map((s) => (s.weekday, s.hour)), [
      (DateTime.friday, 22),
      (DateTime.saturday, 21),
    ]);
  });

  test('days outside the 28-day window and today are ignored', () {
    final h = history(40);
    final g = RiskGrid.compute(h.days, h.hours, now)!;
    expect(g.days, 28);
  });

  test('percentile is nearest-rank', () {
    expect(percentile([1, 2, 3, 4], 0.75), 3);
    expect(percentile([5], 0.75), 5);
    expect(percentile([], 0.75), 0);
  });

  test('upcoming slot starts for the next week', () {
    final h = history(28);
    final g = RiskGrid.compute(h.days, h.hours, now)!;
    final starts = upcomingSlotStarts(g, now);
    expect(starts.first, DateTime(2026, 11, 21, 21)); // tonight
    expect(starts, contains(DateTime(2026, 11, 27, 22))); // next Friday
    expect(starts.every((t) => t.isAfter(now)), isTrue);
  });

  group('heads-up rule', () {
    final slots = [DateTime(2026, 11, 21, 21)];
    test('fires 10-25 minutes before a flagged slot', () {
      expect(headsUpDue(now: DateTime(2026, 11, 21, 20, 50), slotStarts: slots, quiet: []), isTrue);
      expect(headsUpDue(now: DateTime(2026, 11, 21, 20, 35), slotStarts: slots, quiet: []), isTrue);
      expect(headsUpDue(now: DateTime(2026, 11, 21, 20, 30), slotStarts: slots, quiet: []), isFalse);
      expect(headsUpDue(now: DateTime(2026, 11, 21, 20, 55), slotStarts: slots, quiet: []), isFalse);
    });

    test('not in a quiet block, not within an hour of a nudge, not muted', () {
      final at = DateTime(2026, 11, 21, 20, 48);
      expect(headsUpDue(now: at, slotStarts: slots,
          quiet: [(DateTime(2026, 11, 21, 20), DateTime(2026, 11, 21, 21))]), isFalse);
      expect(headsUpDue(now: at, slotStarts: slots, quiet: [],
          lastNudge: at.subtract(const Duration(minutes: 30))), isFalse);
      expect(headsUpDue(now: at, slotStarts: slots, quiet: [],
          lastNudge: at.subtract(const Duration(minutes: 61))), isTrue);
      expect(headsUpDue(now: at, slotStarts: slots, quiet: [], enabled: false), isFalse);
    });
  });

  test('quiet blocks become time ranges, including last night', () {
    final s = ScheduleService([
      ScheduleBlock(id: 'lab', title: 'Lab', type: BlockType.classBlock,
          start: parseHm('20:00'), end: parseHm('01:00'), weekdays: {5}, quiet: true),
      ScheduleBlock(id: 'gym', title: 'Gym', type: BlockType.personal,
          start: parseHm('18:00'), end: parseHm('19:00'), weekdays: {6}),
    ]);
    final q = quietRanges(s, DateTime(2026, 11, 21, 0, 30));
    expect(q.first, (DateTime(2026, 11, 20, 20), DateTime(2026, 11, 21, 1)));
    expect(q.every((r) => r.$1.weekday == DateTime.friday), isTrue); // gym is not quiet
    final plan = headsUpPlanJson([DateTime(2026, 11, 21, 21)], q.take(1).toList());
    expect(plan['slots'], [DateTime(2026, 11, 21, 21).millisecondsSinceEpoch]);
    expect((plan['quiet'] as List).single, hasLength(2));
  });
}
