import '../models/log_entry.dart';
import 'screen_time.dart';

/// Daily averages from opt-in Android usage data. These line up directly with
/// the public dataset's features, so no proxy is needed when they exist.
class ScreenTimeFeatures {
  ScreenTimeFeatures({
    required this.days,
    required this.screenHours,
    required this.socialHours,
    required this.gamingHours,
    required this.videoHours,
    required this.appOpens,
    required this.unlocks,
    required this.lateNightRatio,
    required this.dailyScreenHours,
  });

  final int days;

  /// ~ daily_screen_time_hours
  final double screenHours;

  /// ~ social_media_hours
  final double socialHours;

  /// ~ gaming_hours
  final double gamingHours;
  final double videoHours;

  /// ~ app_opens_per_day
  final double appOpens;
  final double unlocks;

  /// Share of screen time between 23:00 and 05:00.
  final double lateNightRatio;

  /// Hours per day, oldest first (for charts).
  final List<double> dailyScreenHours;

  /// Dataset feature name -> real value, used by the Random Forest.
  Map<String, double> get datasetValues => {
        'daily_screen_time_hours': screenHours,
        'social_media_hours': socialHours,
        'gaming_hours': gamingHours,
        'app_opens_per_day': appOpens,
      };

  static ScreenTimeFeatures? fromDaily(List<UsageSummary> days) {
    if (days.isEmpty) return null;
    double avg(double Function(UsageSummary) f) =>
        days.map(f).reduce((a, b) => a + b) / days.length;
    final total = days.fold(0.0, (a, d) => a + d.totalMinutes);
    final late = days.fold(0.0, (a, d) => a + d.lateNightMinutes);
    return ScreenTimeFeatures(
      days: days.length,
      screenHours: avg((d) => d.totalMinutes) / 60,
      socialHours: avg((d) => d.socialMinutes) / 60,
      gamingHours: avg((d) => d.gamesMinutes) / 60,
      videoHours: avg((d) => d.videoMinutes) / 60,
      appOpens: avg((d) => d.opens.toDouble()),
      unlocks: avg((d) => d.unlocks.toDouble()),
      lateNightRatio: total == 0 ? 0 : late / total,
      dailyScreenHours: days.map((d) => d.totalMinutes / 60).toList(),
    );
  }

  Map<String, dynamic> toPromptJson() => {
        'avg_screen_hours_per_day': double.parse(screenHours.toStringAsFixed(1)),
        'avg_social_media_hours': double.parse(socialHours.toStringAsFixed(1)),
        'avg_gaming_hours': double.parse(gamingHours.toStringAsFixed(1)),
        'avg_video_hours': double.parse(videoHours.toStringAsFixed(1)),
        'avg_unlocks_per_day': unlocks.round(),
        'late_night_share_of_screen_time':
            double.parse(lateNightRatio.toStringAsFixed(2)),
      };
}

/// Feature-engineering layer (thesis Section 3.4.7, Table 3.1).
///
/// Turns raw self-reported logs into the behavioural indicators the risk
/// model consumes. Only episodes count towards usage indicators; check-ins
/// still contribute mood/stress/craving.
class BehaviourFeatures {
  BehaviourFeatures({
    required this.windowDays,
    required this.episodeCount,
    required this.episodesPerDay,
    required this.lateNightRatio,
    required this.meanCraving,
    required this.meanStress,
    required this.meanMood,
    required this.urgeShare,
    required this.resistRate,
    required this.meanDurationMinutes,
    required this.triggerCounts,
    required this.dailyEpisodes,
    this.screen,
  });

  /// Present only when the user granted Usage access.
  final ScreenTimeFeatures? screen;

  final int windowDays;
  final int episodeCount;

  /// ~ app_opens_per_day
  final double episodesPerDay;

  /// ~ sleep_hours / bedtime use
  final double lateNightRatio;

  /// 1–5, ~ problematic intensity
  final double meanCraving;

  /// 1–5, ~ stress_level
  final double meanStress;
  final double meanMood;

  /// ~ notifications_per_day
  final double urgeShare;
  final double resistRate;
  final double meanDurationMinutes;

  /// ~ work_study_hours / academic_work_impact (trigger profile)
  final Map<Trigger, int> triggerCounts;

  /// Episodes per calendar day, oldest first (for charts).
  final List<int> dailyEpisodes;

  bool get hasData => episodeCount > 0 || screen != null;

  Trigger? get topTrigger {
    if (triggerCounts.isEmpty) return null;
    final sorted = triggerCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }

  /// Compact, identifier-free representation sent to the LLM (thesis 3.8).
  Map<String, dynamic> toPromptJson() => {
        'window_days': windowDays,
        'episodes_logged': episodeCount,
        'episodes_per_day': double.parse(episodesPerDay.toStringAsFixed(1)),
        'late_night_ratio': double.parse(lateNightRatio.toStringAsFixed(2)),
        'mean_craving_1to5': double.parse(meanCraving.toStringAsFixed(1)),
        'mean_stress_1to5': double.parse(meanStress.toStringAsFixed(1)),
        'mean_mood_1to5': double.parse(meanMood.toStringAsFixed(1)),
        'resisted_ratio': double.parse(resistRate.toStringAsFixed(2)),
        'avg_episode_minutes': meanDurationMinutes.round(),
        'trigger_counts': {
          for (final e in triggerCounts.entries) e.key.label: e.value
        },
        'episodes_by_day_oldest_first': dailyEpisodes,
        if (screen != null) 'measured_screen_time': screen!.toPromptJson(),
      };

  static BehaviourFeatures fromLogs(List<LogEntry> logs,
      {int windowDays = 7, DateTime? now, ScreenTimeFeatures? screen}) {
    final end = now ?? DateTime.now();
    final startDay = DateTime(end.year, end.month, end.day)
        .subtract(Duration(days: windowDays - 1));
    final recent = logs.where((l) => !l.timestamp.isBefore(startDay)).toList();
    final episodes = recent.where((l) => l.kind == EntryKind.episode).toList();

    double mean(Iterable<num> xs) =>
        xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
    double ratio(int n) => episodes.isEmpty ? 0 : n / episodes.length;

    final triggerCounts = <Trigger, int>{};
    for (final e in episodes) {
      for (final t in e.triggers) {
        triggerCounts[t] = (triggerCounts[t] ?? 0) + 1;
      }
    }

    final daily = List<int>.filled(windowDays, 0);
    for (final e in episodes) {
      final d = DateTime(e.timestamp.year, e.timestamp.month, e.timestamp.day)
          .difference(startDay)
          .inDays;
      if (d >= 0 && d < windowDays) daily[d]++;
    }

    return BehaviourFeatures(
      windowDays: windowDays,
      episodeCount: episodes.length,
      episodesPerDay: episodes.length / windowDays,
      lateNightRatio: ratio(episodes.where((e) => e.isLateNight).length),
      meanCraving: mean(recent.map((e) => e.craving)),
      meanStress: mean(recent.map((e) => e.stress)),
      meanMood: mean(recent.map((e) => e.mood)),
      urgeShare:
          ratio(episodes.where((e) => e.triggers.contains(Trigger.urge)).length),
      resistRate: ratio(episodes.where((e) => e.resisted).length),
      meanDurationMinutes: mean(episodes.map((e) => e.durationMinutes)),
      triggerCounts: triggerCounts,
      dailyEpisodes: daily,
      screen: screen,
    );
  }
}
