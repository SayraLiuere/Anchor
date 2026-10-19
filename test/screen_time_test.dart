import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/screen_time.dart';

UsageSummary day(double total, double social, double late) => UsageSummary.fromMap({
      'totalMinutes': total, 'socialMinutes': social, 'videoMinutes': 0.0,
      'gamesMinutes': 0.0, 'chatMinutes': 0.0, 'unlocks': 80, 'opens': 120,
      'lateNightMinutes': late, 'longestSessionMinutes': 40.0,
      'longestSessionApp': 'TikTok', 'apps': [],
    });

void main() {
  test('measured screen time drives risk without any logs', () {
    final heavy = ScreenTimeFeatures.fromDaily(List.generate(7, (_) => day(540, 300, 120)));
    final light = ScreenTimeFeatures.fromDaily(List.generate(7, (_) => day(90, 20, 0)));
    final rHeavy = HeuristicRiskModel().predict(BehaviourFeatures.fromLogs([], screen: heavy));
    final rLight = HeuristicRiskModel().predict(BehaviourFeatures.fromLogs([], screen: light));
    expect(heavy!.screenHours, 9);
    expect(rHeavy.level.index, greaterThan(rLight.level.index));
    expect(rHeavy.reasons.first, contains('h'));
  });

  test('forest uses real dataset values when measured', () {
    final m = ForestRiskModel.fromJson({
      'features': ['daily_screen_time_hours'],
      'ranges': {'daily_screen_time_hours': [0, 12]},
      'thresholds': {'medium': 0.4, 'high': 0.7},
      'trees': [
        {'left': [1, -1, -1], 'right': [2, -1, -1], 'feature': [0, 0, 0],
         'threshold': [6.0, 0, 0], 'positive': [0.5, 0.1, 0.9]}
      ],
    });
    final s = ScreenTimeFeatures.fromDaily(List.generate(7, (_) => day(420, 100, 0)));
    expect(m.predict(BehaviourFeatures.fromLogs([], screen: s)).level, RiskLevel.high);
  });

  test('nudge settings round-trip', () {
    final n = NudgeSettings(sessionMinutes: 45)..limits['social'] = 30;
    final back = NudgeSettings.fromJson(n.toJson());
    expect(back.sessionMinutes, 45);
    expect(back.limits['social'], 30);
  });
}
