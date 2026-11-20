import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/chat_context.dart';
import 'package:psu_second_brain/services/companion_ai.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/screen_time.dart';

final now = DateTime(2026, 11, 21, 21, 0);

UsageSummary day(int d, double total, {double audio = 0}) => UsageSummary.fromMap({
      'totalMinutes': total + audio, 'socialMinutes': total / 3, 'videoMinutes': total / 4,
      'gamesMinutes': 0.0, 'chatMinutes': 10.0, 'audioMinutes': audio,
      'unlocks': 30, 'opens': 90, 'lateNightMinutes': 60.0,
      'longestSessionMinutes': 40.0, 'longestSessionApp': 'TikTok',
      'dayStart': DateTime(2026, 11, d).millisecondsSinceEpoch,
      'apps': [
        {'package': 'com.zhiliaoapp.musically', 'label': 'TikTok', 'group': 'social', 'minutes': 60.0, 'opens': 5},
      ],
    });

final week = [for (var d = 15; d <= 21; d++) day(d, 540, audio: d == 21 ? 30 : 0)];

final logs = [
  LogEntry(id: 'a', timestamp: DateTime(2026, 11, 20, 23, 0), kind: EntryKind.episode,
      mood: 2, stress: 4, craving: 4, durationMinutes: 50, triggers: [Trigger.lateNight],
      note: 'secret note', appLabel: 'TikTok', appGroup: 'social', draftId: 'x@1'),
];

final risk = RiskResult(RiskLevel.high, 0.874, ['About 9.0h of screen time a day'],
    'Random Forest (100 trees)');

Map<String, dynamic> context() {
  final f = BehaviourFeatures.fromLogs(logs,
      now: now, screen: ScreenTimeFeatures.fromDaily(week));
  return buildRecapContext(now: now, features: f, risk: risk, week: week);
}

void main() {
  test('recap context has the Random Forest result in plain terms', () {
    final r = context()['risk'] as Map<String, dynamic>;
    expect(r['level'], 'High');
    expect(r['model'], 'Random Forest (100 trees)');
    expect(r['estimated_probability_percent'], 87);
    expect(r['reasons'], ['About 9.0h of screen time a day']);
    expect(r['note'], contains('not a diagnosis'));
  });

  test('recap context has a day-by-day table, audio excluded, today marked', () {
    final days = (context()['screen_time_by_day'] as List).cast<Map<String, dynamic>>();
    expect(days, hasLength(7));
    expect(days.first['day'], 'Sun 15 Nov');
    expect(days.last['day'], 'Sat 21 Nov (today so far)');
    expect(days.first['screen_hours'], 9.0);
    expect(days.last['screen_hours'], 9.0); // the 30 min of music is not screen time
    expect(days.first['social_hours'], 3.0);
    expect(days.first['late_night_hours'], 1.0);
  });

  test('no names, app names or notes in what the recap sends', () {
    final (system, messages) = CompanionAI.recapPrompt(context());
    final sent = [system, for (final (_, t) in messages) t].join('\n');
    for (final secret in ['TikTok', 'secret note', 'com.zhiliaoapp', 'x@1']) {
      expect(sent, isNot(contains(secret)), reason: secret);
    }
    expect(system, CompanionAI.recapPersona);
    expect(messages.single.$2, startsWith("Write this week's report from this data:"));
  });

  test('offline, the template report keeps Overview, Patterns and Suggestions', () async {
    final ai = CompanionAI(proxyUrl: '');
    final f = BehaviourFeatures.fromLogs(logs,
        now: now, screen: ScreenTimeFeatures.fromDaily(week));
    final report = await ai.weeklySummary(f, risk, context: context());
    for (final h in ['Overview', 'Patterns', 'Suggestions']) {
      expect(report, contains('$h\n'), reason: h);
    }
    expect(report, contains('high'));
  });

  test('without screen time the recap still builds (no day table)', () {
    final c = buildRecapContext(
        now: now,
        features: BehaviourFeatures.fromLogs(logs, now: now),
        risk: RiskResult(RiskLevel.low, 0.1, [], 'Heuristic engine (MVP)'),
        week: const []);
    expect(c.containsKey('screen_time_by_day'), isFalse);
    expect((c['risk'] as Map)['model'], 'Heuristic engine (MVP)');
  });
}
