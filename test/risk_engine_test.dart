import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/screen_time.dart';

/// The forest bundled with the app (A1).
ForestRiskModel bundledForest() => ForestRiskModel.fromJson(
    jsonDecode(File('assets/model/rf_model.json').readAsStringSync())
        as Map<String, dynamic>);

UsageSummary day(double totalMin, double socialMin, {double gamesMin = 0}) =>
    UsageSummary.fromMap({
      'totalMinutes': totalMin, 'socialMinutes': socialMin, 'videoMinutes': 0.0,
      'gamesMinutes': gamesMin, 'chatMinutes': 0.0, 'unlocks': 60, 'opens': 90,
      'lateNightMinutes': 0.0, 'longestSessionMinutes': 30.0,
      'longestSessionApp': null, 'apps': [],
    });

BehaviourFeatures withScreen(double totalMin, double socialMin) =>
    BehaviourFeatures.fromLogs([],
        screen: ScreenTimeFeatures.fromDaily(
            List.generate(7, (_) => day(totalMin, socialMin))));

BehaviourFeatures logsOnly() {
  final now = DateTime.now();
  return BehaviourFeatures.fromLogs([
    LogEntry(id: '1', timestamp: now, kind: EntryKind.episode, mood: 2,
        stress: 4, craving: 4, durationMinutes: 40, triggers: [Trigger.stress]),
  ], now: now);
}

void main() {
  final engine = RiskEngine(forest: bundledForest());

  test('bundled forest loads with all 8 features mapped', () {
    final f = engine.forest!;
    expect(f.trees, hasLength(100));
    expect(f.features, hasLength(8));
    expect(f.features.every(ForestRiskModel.featureSource.containsKey), isTrue);
  });

  test('screen time on -> Random Forest', () {
    final r = engine.predict(withScreen(300, 120));
    expect(r.modelName, startsWith('Random Forest'));
    expect(engine.modelFor(withScreen(300, 120)), same(engine.forest));
  });

  test('screen time off -> heuristic, even when the forest is loaded', () {
    final r = engine.predict(logsOnly());
    expect(r.modelName, startsWith('Heuristic'));
  });

  test('no forest bundled -> heuristic even with screen time', () {
    expect(RiskEngine().predict(withScreen(300, 120)).modelName,
        startsWith('Heuristic'));
  });

  test('forest rates heavy use above light use', () {
    final light = engine.predict(withScreen(120, 20));
    final heavy = engine.predict(withScreen(600, 300));
    expect(heavy.score, greaterThan(light.score));
    expect(heavy.level, RiskLevel.high);
  });
}
