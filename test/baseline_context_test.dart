import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/baseline.dart';
import 'package:psu_second_brain/services/chat_context.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/screen_time.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

void main() {
  // 14 saved days with 120 min of video at 18:00 and 60 min of social at 09:00.
  final saved = [
    for (var d = 1; d <= 14; d++)
      buildSnapshots([
        RawSession('social', DateTime(2026, 11, d, 9), DateTime(2026, 11, d, 10)),
        RawSession('video', DateTime(2026, 11, d, 18), DateTime(2026, 11, d, 20)),
      ], [], [dateKey(DateTime(2026, 11, d))]),
  ];
  final b = Baseline.from([for (final s in saved) ...s.days], [for (final s in saved) ...s.hours])!;
  final risk = RiskResult(RiskLevel.low, 0.1, [], 'h');
  final now = DateTime(2026, 11, 21, 20, 30);

  test("Mira's context compares today with the usual by now", () {
    final today = UsageSummary.fromMap({
      'totalMinutes': 228.0, 'socialMinutes': 60.0, 'videoMinutes': 168.0,
      'gamesMinutes': 0.0, 'chatMinutes': 0.0, 'unlocks': 0, 'opens': 0,
      'lateNightMinutes': 0.0, 'longestSessionMinutes': 0.0, 'longestSessionApp': null, 'apps': [],
    });
    final c = buildChatContext(
        now: now,
        features: BehaviourFeatures.fromLogs(const <LogEntry>[], now: now),
        risk: risk,
        logs: const [],
        deviations: b.compareToday(today, now));
    final video = (c['today_vs_usual_by_now'] as List).firstWhere((x) => x['category'] == 'video');
    expect(video['today_minutes'], 168);
    expect(video['usual_minutes_by_now'], 120);
    expect(video['percent_difference'], 40);
  });

  test('the recap compares this week with the usual day', () {
    final week = [
      for (var d = 15; d <= 21; d++)
        UsageSummary.fromMap({
          'totalMinutes': 240.0, 'socialMinutes': 60.0, 'videoMinutes': 180.0,
          'gamesMinutes': 0.0, 'chatMinutes': 0.0, 'unlocks': 0, 'opens': 0,
          'lateNightMinutes': 0.0, 'longestSessionMinutes': 0.0, 'longestSessionApp': null,
          'dayStart': DateTime(2026, 11, d).millisecondsSinceEpoch, 'apps': [],
        }),
    ];
    final c = buildRecapContext(
        now: now, features: BehaviourFeatures.fromLogs(const <LogEntry>[], now: now),
        risk: risk, week: week, baseline: b);
    final v = c['compared_with_usual'] as Map<String, dynamic>;
    expect(v['usual_from_saved_days'], 14);
    expect(v['video'], {'this_week_hours_per_day': 3.0, 'usual_hours_per_day': 2.0, 'percent_difference': 50});
    expect(buildRecapContext(now: now, features: BehaviourFeatures.fromLogs(const <LogEntry>[], now: now),
        risk: risk, week: week).containsKey('compared_with_usual'), isFalse);
  });
}
