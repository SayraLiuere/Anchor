import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

DateTime t(int day, int h, [int m = 0]) => DateTime(2026, 11, day, h, m);

double hourMin(List<HourUsage> hs, String date, int hour, String cat) => hs
    .where((h) => h.date == date && h.hour == hour && h.category == cat)
    .fold(0.0, (a, h) => a + h.minutes);

void main() {
  test('a session across midnight is split between the two days', () {
    final r = buildSnapshots(
      [RawSession('social', t(17, 23, 30), t(18, 0, 45))],
      [t(17, 23, 29)],
      ['2026-11-17', '2026-11-18'],
    );
    final d17 = r.days.firstWhere((d) => d.date == '2026-11-17');
    final d18 = r.days.firstWhere((d) => d.date == '2026-11-18');
    expect(d17.group('social'), 30);
    expect(d18.group('social'), 45);
    expect(d17.lateNightMinutes, 30);
    expect(d18.lateNightMinutes, 45);
    expect(hourMin(r.hours, '2026-11-17', 23, 'social'), 30);
    expect(hourMin(r.hours, '2026-11-18', 0, 'social'), 45);
    // The open and the unlock belong to the day the session started.
    expect(d17.opens, 1);
    expect(d18.opens, 0);
    expect(d17.unlocks, 1);
    expect(d18.unlocks, 0);
  });

  test('sessions are split at every hour; hourly rows are non-zero only', () {
    final r = buildSnapshots(
      [
        RawSession('video', t(17, 10, 50), t(17, 12, 10)),
        RawSession('chat', t(17, 11, 0), t(17, 11, 5)),
      ],
      [],
      ['2026-11-17'],
    );
    expect(hourMin(r.hours, '2026-11-17', 10, 'video'), 10);
    expect(hourMin(r.hours, '2026-11-17', 11, 'video'), 60);
    expect(hourMin(r.hours, '2026-11-17', 12, 'video'), 10);
    expect(r.hours, hasLength(4));
    expect(r.hours.every((h) => h.minutes > 0), isTrue);
    final d = r.days.single;
    expect(d.totalMinutes, 85);
    expect(d.lateNightMinutes, 0);
  });

  test('days outside the requested set are ignored; unknown groups are other', () {
    final r = buildSnapshots(
      [
        RawSession('social', t(16, 22, 0), t(16, 23, 0)), // read started early
        RawSession('mystery', t(17, 9, 0), t(17, 9, 20)),
      ],
      [t(16, 22, 0), t(17, 9, 0), t(17, 13, 0)],
      ['2026-11-17'],
    );
    expect(r.days.map((d) => d.date), ['2026-11-17']);
    expect(r.days.single.group('other'), 20);
    expect(r.days.single.group('social'), 0);
    expect(r.days.single.unlocks, 2);
    expect(r.hours.every((h) => h.date == '2026-11-17'), isTrue);
  });

  test('rows round-trip through JSON, and old rows load with defaults', () {
    final r = buildSnapshots(
        [RawSession('games', t(17, 20, 0), t(17, 21, 30))], [t(17, 20, 0)], ['2026-11-17']);
    final back = DaySnapshot.fromJson(r.days.single.toJson());
    expect(back.date, '2026-11-17');
    expect(back.group('games'), 90);
    expect(back.totalMinutes, 90);
    expect(back.unlocks, 1);
    expect(back.opens, 1);
    expect(r.days.single.toJson()['total_min'], 90);
    expect(r.days.single.toJson()['audio_min'], 0);

    final old = DaySnapshot.fromJson({'date': '2026-11-10', 'social_min': 12});
    expect(old.group('social'), 12);
    expect(old.group('audio'), 0);
    expect(old.opens, 0);

    expect(r.hours, hasLength(2)); // 20:00–21:00 and 21:00–21:30
    final h = HourUsage.fromJson(r.hours.last.toJson());
    expect((h.date, h.hour, h.category, h.minutes), ('2026-11-17', 21, 'games', 30.0));
  });

  test('missing days are complete days only, oldest first, not already stored', () {
    final now = t(20, 9);
    expect(missingDays(['2026-11-18', '2026-11-15'], now), [
      '2026-11-13', '2026-11-14', '2026-11-16', '2026-11-17', '2026-11-19',
    ]);
    expect(missingDays([], now), isNot(contains('2026-11-20')));
  });

  test('the week window uses stored rows, then today, oldest first', () {
    final stored = buildSnapshots([
      RawSession('social', t(18, 10), t(18, 12)),
      RawSession('social', t(19, 10), t(19, 11)),
      RawSession('social', t(5, 10), t(5, 11)), // too old for the window
    ], [], ['2026-11-18', '2026-11-19', '2026-11-05']).days;
    final today = DaySnapshot(
        date: '2026-11-20', minutes: {'video': 30}, unlocks: 3, opens: 4,
        lateNightMinutes: 0).toSummary();
    final week = weekFromSnapshots(stored, today, t(20, 9));
    expect(week.map((d) => d.totalMinutes), [120, 60, 30]);
    expect(week.first.dayStart, DateTime(2026, 11, 18));

    final f = ScreenTimeFeatures.fromDaily(week)!;
    expect(f.days, 3);
    expect(f.socialHours, closeTo(1, 1e-9)); // (2 + 1 + 0) h / 3 days
  });
}
