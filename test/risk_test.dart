import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';

LogEntry ep(DateTime at, {int craving = 3, int stress = 3, bool resisted = false, List<Trigger> t = const []}) =>
    LogEntry(id: '$at', timestamp: at, kind: EntryKind.episode, mood: 3, stress: stress,
        craving: craving, triggers: t, durationMinutes: 30, resisted: resisted);

void main() {
  final now = DateTime(2026, 10, 19, 15);

  test('no logs -> low risk', () {
    final r = HeuristicRiskModel().predict(BehaviourFeatures.fromLogs([], now: now));
    expect(r.level, RiskLevel.low);
  });

  test('feature mapping counts late-night and urge episodes', () {
    final logs = [
      ep(DateTime(2026, 10, 19, 1), t: [Trigger.urge]),
      ep(DateTime(2026, 10, 18, 14)),
      ep(DateTime(2026, 10, 1, 14)), // outside 7-day window
    ];
    final f = BehaviourFeatures.fromLogs(logs, now: now);
    expect(f.episodeCount, 2);
    expect(f.lateNightRatio, 0.5);
    expect(f.urgeShare, 0.5);
    expect(f.dailyEpisodes.last, 1);
  });

  test('heavy, late, high-urge use -> high risk', () {
    final logs = [
      for (var d = 0; d < 7; d++)
        for (var k = 0; k < 6; k++)
          ep(DateTime(2026, 10, 19 - d, 0, k), craving: 5, stress: 5, t: [Trigger.urge])
    ];
    final r = HeuristicRiskModel().predict(BehaviourFeatures.fromLogs(logs, now: now));
    expect(r.level, RiskLevel.high);
    expect(r.reasons, isNotEmpty);
  });

  test('forest JSON evaluates', () {
    final m = ForestRiskModel.fromJson({
      'features': ['stress_level'],
      'ranges': {'stress_level': [1, 10]},
      'thresholds': {'medium': 0.4, 'high': 0.7},
      'trees': [
        {'left': [1, -1, -1], 'right': [2, -1, -1], 'feature': [0, 0, 0],
         'threshold': [5.0, 0, 0], 'positive': [0.5, 0.1, 0.9]}
      ],
    });
    final calm = m.predict(BehaviourFeatures.fromLogs([ep(now, stress: 1)], now: now));
    final tense = m.predict(BehaviourFeatures.fromLogs([ep(now, stress: 5)], now: now));
    expect(calm.level, RiskLevel.low);
    expect(tense.level, RiskLevel.high);
  });
}
