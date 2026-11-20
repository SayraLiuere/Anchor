import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/services/baseline.dart';
import 'package:psu_second_brain/services/screen_time.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

/// A saved day on 2026-11-[day] with [video] minutes spread over 18:00-21:00
/// and 60 min of social at 09:00.
({List<DaySnapshot> days, List<HourUsage> hours}) day(int d, double video,
        {double audio = 0}) =>
    buildSnapshots([
      RawSession('social', DateTime(2026, 11, d, 9), DateTime(2026, 11, d, 10)),
      RawSession('video', DateTime(2026, 11, d, 18),
          DateTime(2026, 11, d, 18).add(Duration(minutes: video.round()))),
      if (audio > 0)
        RawSession('audio', DateTime(2026, 11, d, 7),
            DateTime(2026, 11, d, 7).add(Duration(minutes: audio.round()))),
    ], [], [dateKey(DateTime(2026, 11, d))]);

Baseline? baseline(List<int> dayNums, double Function(int) video) {
  final all = [for (final d in dayNums) day(d, video(d))];
  return Baseline.from([for (final a in all) ...a.days], [for (final a in all) ...a.hours]);
}

UsageSummary today({double video = 0, double social = 0}) => UsageSummary.fromMap({
      'totalMinutes': video + social, 'socialMinutes': social, 'videoMinutes': video,
      'gamesMinutes': 0.0, 'chatMinutes': 0.0, 'unlocks': 0, 'opens': 0,
      'lateNightMinutes': 0.0, 'longestSessionMinutes': 0.0, 'longestSessionApp': null,
      'apps': [],
    });

void main() {
  test('median of odd, even and empty lists', () {
    expect(median([5, 1, 3]), 3);
    expect(median([4, 1, 3, 2]), 2.5);
    expect(median([]), 0);
  });

  test('no baseline before 7 saved days (the card stays hidden)', () {
    expect(baseline([1, 2, 3, 4, 5, 6], (_) => 60), isNull);
    expect(baseline([1, 2, 3, 4, 5, 6, 7], (_) => 60), isNotNull);
  });

  test('same-weekday median with 2+ samples, overall median otherwise', () {
    // Nov 2, 9, 16 are Mondays with 120, 140, 160 min of video; the other
    // days have 30. Nov 3 and 10 are Tuesdays (2 samples); Sundays only 1.
    final b = baseline([2, 3, 4, 5, 6, 7, 8, 9, 10, 16],
        (d) => {2: 120.0, 9: 140.0, 16: 160.0}[d] ?? 30)!;
    expect(b.usualDay('video', DateTime.monday), 140);
    expect(b.usualDay('video', DateTime.tuesday), 30);
    final (_, sunByWeekday) = b.usualBy('video', DateTime.sunday, 23 * 60);
    expect(sunByWeekday, isFalse); // only one Sunday -> overall median
    expect(b.usualDay('video', DateTime.sunday), 30);
  });

  test('by-now comparison only counts the usual up to the same time', () {
    final b = baseline([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], (_) => 120)!;
    // Video runs 18:00-20:00. By 19:30 the usual is 90 min, by 10:00 it is 0.
    expect(b.usualBy('video', DateTime.saturday, 19 * 60 + 30).$1, 90);
    expect(b.usualBy('video', DateTime.saturday, 10 * 60).$1, 0);
    expect(b.usualBy('social', DateTime.saturday, 9 * 60 + 30).$1, 30);
  });

  test('Home card: the largest real rise; usual days show nothing', () {
    final b = baseline([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], (_) => 120)!;
    final sat2030 = DateTime(2026, 11, 21, 20, 30); // usual video by now: 120
    final ds = b.compareToday(today(video: 168, social: 60), sat2030);
    final h = headlineDeviation(ds)!;
    expect(h.category, 'video');
    expect(h.percent!.round(), 40);
    expect(h.usualPhrase, 'your usual Saturday');
    expect(headlineDeviation(b.compareToday(today(video: 125, social: 60), sat2030)), isNull);
  });

  test('large deviations become risk reasons', () {
    final b = baseline([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14], (_) => 120)!;
    final reasons = deviationReasons(
        b.compareToday(today(video: 200, social: 60), DateTime(2026, 11, 21, 20, 30)));
    expect(reasons, ['Videos 67% above your usual Saturday so far']);
    expect(deviationReasons(
        b.compareToday(today(video: 150, social: 60), DateTime(2026, 11, 21, 20, 30))), isEmpty);
  });

  test('suggested limits: median day minus 10%, rounded to 5 min', () {
    final b = baseline([1, 2, 3, 4, 5, 6, 7], (d) => 100.0 + d)!; // median 104
    final s = b.suggestedLimits();
    expect(s['video'], 95); // 104 * 0.9 = 93.6 -> 95
    expect(s['social'], 55); // 60 * 0.9 = 54 -> 55
    expect(s['total'], 150); // 164 * 0.9 = 147.6 -> 150
    expect(s.containsKey('games'), isFalse); // under 10 min: no suggestion
  });

  test('music never counts as screen time in the baseline', () {
    final withMusic = [for (var d = 1; d <= 7; d++) day(d, 60, audio: 120)];
    final b = Baseline.from([for (final a in withMusic) ...a.days], [for (final a in withMusic) ...a.hours])!;
    expect(b.usualDay('screen', DateTime.monday), 120); // 60 social + 60 video
  });
}
