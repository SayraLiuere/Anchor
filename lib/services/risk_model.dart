import 'dart:convert';

import 'package:flutter/services.dart';

import 'features.dart';

enum RiskLevel { low, medium, high }

extension RiskLevelLabel on RiskLevel {
  String get label => switch (this) {
        RiskLevel.low => 'Low',
        RiskLevel.medium => 'Medium',
        RiskLevel.high => 'High',
      };
}

class RiskResult {
  RiskResult(this.level, this.score, this.reasons, this.modelName);

  final RiskLevel level;

  /// 0–1, probability-like score.
  final double score;

  /// Human-readable contributing factors, strongest first.
  final List<String> reasons;
  final String modelName;
}

/// Swappable risk component (thesis Section 4.6). The app starts with the
/// heuristic engine and switches to the trained forest if
/// `assets/model/rf_model.json` is present.
abstract class RiskModel {
  String get name;
  RiskResult predict(BehaviourFeatures f);

  static Future<RiskModel> load() async {
    try {
      final raw = await rootBundle.loadString('assets/model/rf_model.json');
      return ForestRiskModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return HeuristicRiskModel();
    }
  }
}

double _clamp01(double x) => x.clamp(0.0, 1.0);

/// Per-indicator intensities in 0..1, shared by both models so the
/// explanations stay consistent.
///
/// When measured screen time exists it replaces the log-based estimates for
/// time and late-night use; otherwise everything comes from the logs.
Map<String, double> _intensities(BehaviourFeatures f) {
  final s = f.screen;
  final loggedLate = f.lateNightRatio;
  return {
    'frequency': _clamp01(f.episodesPerDay / 6),
    // A third of screen time after 23:00 already counts as maximal.
    'lateNight': s == null
        ? loggedLate
        : (loggedLate > s.lateNightRatio * 3 ? loggedLate : _clamp01(s.lateNightRatio * 3)),
    'craving': _clamp01((f.meanCraving - 1) / 4),
    'stress': _clamp01((f.meanStress - 1) / 4),
    'urge': f.urgeShare,
    'notResisting': f.episodeCount > 0 ? 1 - f.resistRate : 0,
    'screenTime': s == null
        ? _clamp01(f.episodesPerDay * f.meanDurationMinutes / (6 * 60))
        : _clamp01(s.screenHours / 8),
    // Without measured data these fall back to the log-based time estimate.
    'social': s == null
        ? _clamp01(f.episodesPerDay * f.meanDurationMinutes / (6 * 60))
        : _clamp01((s.socialHours + s.videoHours) / 4),
    'gaming': s == null
        ? _clamp01(f.episodesPerDay * f.meanDurationMinutes / (6 * 60))
        : _clamp01(s.gamingHours / 3),
  };
}

String _reasonText(String key, BehaviourFeatures f) {
  final s = f.screen;
  return switch (key) {
    'frequency' => 'Frequent episodes logged this week',
    'lateNight' => s != null
        ? 'A lot of phone time happens late at night'
        : 'Many episodes happen late at night',
    'craving' => 'Strong urges to check your phone',
    'stress' => 'Stress has been running high',
    'urge' => 'Notifications and urges often start an episode',
    'notResisting' => 'Most urges ended in continued use',
    'screenTime' => s != null
        ? 'About ${s.screenHours.toStringAsFixed(1)}h of screen time a day'
        : 'Long episodes add up to a lot of time',
    'social' => s != null
        ? '${(s.socialHours + s.videoHours).toStringAsFixed(1)}h a day on social media and videos'
        : '',
    'gaming' => s != null ? '${s.gamingHours.toStringAsFixed(1)}h a day gaming' : '',
    _ => key,
  };
}

List<String> _topReasons(Map<String, double> weighted, BehaviourFeatures f,
    {int n = 3}) {
  final sorted = weighted.entries.where((e) => e.value > 0.04).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.take(n).map((e) => _reasonText(e.key, f)).toList();
}

RiskLevel _bucket(double s, double medium, double high) =>
    s >= high ? RiskLevel.high : (s >= medium ? RiskLevel.medium : RiskLevel.low);

/// MVP heuristic engine (thesis 4.6: stress, craving, triggers), extended
/// with measured screen time when the user opts in.
class HeuristicRiskModel implements RiskModel {
  static const logWeights = {
    'frequency': 0.25,
    'lateNight': 0.20,
    'craving': 0.20,
    'stress': 0.15,
    'urge': 0.10,
    'notResisting': 0.10,
  };

  static const screenWeights = {
    'screenTime': 0.20,
    'social': 0.15,
    'lateNight': 0.15,
    'craving': 0.12,
    'frequency': 0.10,
    'stress': 0.10,
    'gaming': 0.08,
    'notResisting': 0.05,
    'urge': 0.05,
  };

  static Map<String, double> weightsFor(BehaviourFeatures f) =>
      f.screen == null ? logWeights : screenWeights;

  @override
  String get name => 'Heuristic engine (MVP)';

  @override
  RiskResult predict(BehaviourFeatures f) {
    if (!f.hasData) {
      return RiskResult(RiskLevel.low, 0, ['Not enough logs yet'], name);
    }
    final i = _intensities(f);
    final w = weightsFor(f);
    final weighted = {for (final k in w.keys) k: w[k]! * i[k]!};
    final score = weighted.values.fold(0.0, (a, b) => a + b);
    return RiskResult(
        _bucket(score, 0.35, 0.6), score, _topReasons(weighted, f), name);
  }
}

/// Evaluates a Random Forest exported by `ml/train_model.py`.
///
/// The forest was trained on the public dataset's aggregate features; at
/// runtime each feature is approximated from a log-derived intensity and
/// projected onto that feature's training range (the conceptual mapping in
/// thesis Table 3.1). These mappings are assumptions, not validated proxies.
class ForestRiskModel implements RiskModel {
  ForestRiskModel._(this.features, this.ranges, this.trees, this.medium,
      this.high, this.invert);

  final List<String> features;
  final Map<String, List<double>> ranges;
  final List<DecisionTree> trees;
  final double medium, high;

  /// Features where a *higher* log intensity means a *lower* dataset value.
  final Set<String> invert;

  /// Which log intensity stands in for each dataset feature.
  static const featureSource = {
    'app_opens_per_day': 'frequency',
    'notifications_per_day': 'urge',
    'sleep_hours': 'lateNight',
    'stress_level': 'stress',
    'daily_screen_time_hours': 'screenTime',
    'social_media_hours': 'social',
    'gaming_hours': 'gaming',
    'weekend_screen_time': 'screenTime',
    'academic_work_impact': 'craving',
  };

  factory ForestRiskModel.fromJson(Map<String, dynamic> j) {
    final features = (j['features'] as List).cast<String>();
    for (final f in features) {
      if (!featureSource.containsKey(f)) {
        throw FormatException('No log-derived mapping for feature "$f"');
      }
    }
    return ForestRiskModel._(
      features,
      (j['ranges'] as Map<String, dynamic>).map((k, v) =>
          MapEntry(k, (v as List).map((x) => (x as num).toDouble()).toList())),
      (j['trees'] as List)
          .map((t) => DecisionTree.fromJson(t as Map<String, dynamic>))
          .toList(),
      (j['thresholds']['medium'] as num).toDouble(),
      (j['thresholds']['high'] as num).toDouble(),
      {'sleep_hours'},
    );
  }

  @override
  String get name => 'Random Forest (${trees.length} trees)';

  @override
  RiskResult predict(BehaviourFeatures f) {
    if (!f.hasData) {
      return RiskResult(RiskLevel.low, 0, ['Not enough logs yet'], name);
    }
    final i = _intensities(f);
    final measured = f.screen?.datasetValues ?? const {};
    final x = [
      for (final name in features)
        () {
          // Real screen-time values need no mapping.
          if (measured.containsKey(name)) return measured[name]!;
          final r = ranges[name]!;
          var t = i[featureSource[name]]!;
          if (invert.contains(name)) t = 1 - t;
          return r[0] + t * (r[1] - r[0]);
        }()
    ];
    final p = trees.map((t) => t.predictPositive(x)).reduce((a, b) => a + b) /
        trees.length;
    final w = HeuristicRiskModel.weightsFor(f);
    return RiskResult(
      _bucket(p, medium, high),
      p,
      _topReasons({for (final k in w.keys) k: w[k]! * i[k]!}, f),
      name,
    );
  }
}

class DecisionTree {
  DecisionTree(this.left, this.right, this.feature, this.threshold, this.positive);

  final List<int> left, right, feature;
  final List<double> threshold;

  /// Fraction of positive (addicted) samples at each node.
  final List<double> positive;

  factory DecisionTree.fromJson(Map<String, dynamic> j) {
    List<int> ints(String k) => (j[k] as List).cast<int>();
    List<double> dbls(String k) =>
        (j[k] as List).map((x) => (x as num).toDouble()).toList();
    return DecisionTree(ints('left'), ints('right'), ints('feature'),
        dbls('threshold'), dbls('positive'));
  }

  double predictPositive(List<double> x) {
    var node = 0;
    while (left[node] != -1) {
      node = x[feature[node]] <= threshold[node] ? left[node] : right[node];
    }
    return positive[node];
  }
}
