import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/screen_time.dart';
import 'package:psu_second_brain/services/usage_snapshots.dart';

UsageSummary day({double audio = 0}) => UsageSummary.fromMap({
      'totalMinutes': 420.0 + audio, 'socialMinutes': 150.0, 'videoMinutes': 90.0,
      'gamesMinutes': 20.0, 'chatMinutes': 40.0, 'audioMinutes': audio,
      'unlocks': 40, 'opens': 120, 'lateNightMinutes': 60.0,
      'longestSessionMinutes': 45.0, 'longestSessionApp': null, 'apps': [],
    });

BehaviourFeatures week({double audio = 0}) => BehaviourFeatures.fromLogs([],
    screen: ScreenTimeFeatures.fromDaily(List.generate(7, (_) => day(audio: audio))));

void main() {
  final forest = ForestRiskModel.fromJson(
      jsonDecode(File('assets/model/rf_model.json').readAsStringSync())
          as Map<String, dynamic>);
  final engine = RiskEngine(forest: forest);

  test('audio minutes do not change the risk score (forest and heuristic)', () {
    final base = week();
    final withMusic = week(audio: 180); // 3 h of music a day on top
    expect(withMusic.screen!.screenHours, base.screen!.screenHours);
    expect(withMusic.screen!.lateNightRatio, base.screen!.lateNightRatio);
    expect(engine.predict(withMusic).score, engine.predict(base).score);
    expect(HeuristicRiskModel().predict(withMusic).score,
        HeuristicRiskModel().predict(base).score);
  });

  test('audio is stored and counted in the total, but never as late night', () {
    final r = buildSnapshots([
      RawSession('audio', DateTime(2026, 11, 20, 23, 0), DateTime(2026, 11, 20, 23, 50)),
      RawSession('social', DateTime(2026, 11, 20, 23, 50), DateTime(2026, 11, 21, 0, 0)),
    ], [], ['2026-11-20']);
    final d = r.days.single;
    expect(d.group('audio'), 50);
    expect(d.totalMinutes, 60);
    expect(d.lateNightMinutes, 10); // only the social part
    expect(r.hours.map((h) => h.category).toSet(), {'audio', 'social'});
    // Through the stored row, risk sees 10 min of screen time, not 60.
    final s = d.toSummary();
    expect(s.audioMinutes, 50);
    expect(s.screenMinutes, 10);
  });

  test('new rows are stamped with the counting version; old rows stay unstamped', () {
    final r = buildSnapshots(
        [RawSession('video', DateTime(2026, 11, 20, 9), DateTime(2026, 11, 20, 10))],
        [], ['2026-11-20']);
    final j = r.days.single.toJson();
    expect(j['counting_version'], countingVersion);
    expect(countingVersion, 3);
    expect(DaySnapshot.fromJson(j).countingVersion, 3);

    final old = DaySnapshot.fromJson({'date': '2026-11-13', 'other_min': 194.0});
    expect(old.countingVersion, isNull);
    expect(old.toJson().containsKey('counting_version'), isFalse);
  });

  test('a live day read without audioMinutes (older native code) loads as 0', () {
    final m = {
      'totalMinutes': 30.0, 'socialMinutes': 30.0, 'videoMinutes': 0.0,
      'gamesMinutes': 0.0, 'chatMinutes': 0.0, 'unlocks': 1, 'opens': 1,
      'lateNightMinutes': 0.0, 'longestSessionMinutes': 30.0,
      'longestSessionApp': null, 'apps': [],
    };
    final s = UsageSummary.fromMap(m);
    expect(s.audioMinutes, 0);
    expect(s.screenMinutes, 30);
  });
}
