import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// One app's foreground time in a period.
class AppUsageInfo {
  AppUsageInfo(this.package, this.label, this.group, this.minutes, this.opens);

  final String package, label, group;
  final double minutes;
  final int opens;
}

/// Screen-time summary for one period (usually one day), read from Android's
/// UsageStatsManager after the user grants "Usage access".
class UsageSummary {
  UsageSummary.fromMap(Map<dynamic, dynamic> m)
      : totalMinutes = (m['totalMinutes'] as num).toDouble(),
        socialMinutes = (m['socialMinutes'] as num).toDouble(),
        videoMinutes = (m['videoMinutes'] as num).toDouble(),
        gamesMinutes = (m['gamesMinutes'] as num).toDouble(),
        chatMinutes = (m['chatMinutes'] as num).toDouble(),
        unlocks = m['unlocks'] as int,
        opens = m['opens'] as int,
        lateNightMinutes = (m['lateNightMinutes'] as num).toDouble(),
        longestSessionMinutes = (m['longestSessionMinutes'] as num).toDouble(),
        longestSessionApp = m['longestSessionApp'] as String?,
        dayStart = m['dayStart'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['dayStart'] as int),
        apps = (m['apps'] as List)
            .map((a) => AppUsageInfo(
                  a['package'] as String,
                  a['label'] as String,
                  a['group'] as String,
                  (a['minutes'] as num).toDouble(),
                  a['opens'] as int,
                ))
            .toList();

  final double totalMinutes, socialMinutes, videoMinutes, gamesMinutes, chatMinutes;
  final int unlocks, opens;
  final double lateNightMinutes, longestSessionMinutes;
  final String? longestSessionApp;
  final DateTime? dayStart;
  final List<AppUsageInfo> apps;
}

/// A long social/video/game session found in usage data. It becomes a draft
/// episode the user can confirm with a reason, or skip.
class DetectedSession {
  DetectedSession({
    required this.id,
    required this.package,
    required this.label,
    required this.group,
    required this.start,
    required this.end,
    required this.minutes,
    this.ongoing = false,
  });

  DetectedSession.fromMap(Map<dynamic, dynamic> m)
      : id = m['id'] as String,
        package = m['package'] as String,
        label = m['label'] as String,
        group = m['group'] as String,
        start = DateTime.fromMillisecondsSinceEpoch(m['start'] as int),
        end = DateTime.fromMillisecondsSinceEpoch(m['end'] as int),
        minutes = (m['minutes'] as num).toDouble(),
        ongoing = m['ongoing'] as bool? ?? false;

  /// "package@startMillis", the same id the background watcher uses.
  final String id;
  final String package, label, group;
  final DateTime start, end;
  final double minutes;
  final bool ongoing;

  /// Start time encoded in a draft id, used to prune old dismissals.
  static DateTime? startOf(String id) {
    final ms = int.tryParse(id.split('@').last);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

/// Sessions still waiting for a reason: finished, not skipped, not logged yet.
/// Newest first.
List<DetectedSession> pendingDrafts(
  List<DetectedSession> sessions, {
  required Set<String> dismissed,
  required Set<String> logged,
}) =>
    sessions
        .where((s) => !s.ongoing && !dismissed.contains(s.id) && !logged.contains(s.id))
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));

/// Limits and reminders, enforced by the native background watcher.
class NudgeSettings {
  NudgeSettings({
    this.warningsEnabled = true,
    Map<String, int>? limits,
    this.sessionMinutes = 30,
    this.logReminder = true,
    this.reminderHour = 21,
    this.askAfterSession = true,
    this.draftMinutes = 15,
  }) : limits = limits ?? {'social': 60, 'games': 60, 'video': 90, 'total': 300};

  bool warningsEnabled;
  Map<String, int> limits;
  int sessionMinutes;
  bool logReminder;
  int reminderHour;

  /// Notify after a long session ends, asking what pulled the user in.
  bool askAfterSession;

  /// Minimum length for a session to become a draft episode.
  int draftMinutes;

  Map<String, dynamic> toJson() => {
        'warningsEnabled': warningsEnabled,
        'limits': limits,
        'sessionMinutes': sessionMinutes,
        'logReminder': logReminder,
        'reminderHour': reminderHour,
        'askAfterSession': askAfterSession,
        'draftMinutes': draftMinutes,
      };

  factory NudgeSettings.fromJson(Map<String, dynamic> j) => NudgeSettings(
        warningsEnabled: j['warningsEnabled'] as bool? ?? true,
        limits: (j['limits'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, v as int)),
        sessionMinutes: j['sessionMinutes'] as int? ?? 30,
        logReminder: j['logReminder'] as bool? ?? true,
        reminderHour: j['reminderHour'] as int? ?? 21,
        askAfterSession: j['askAfterSession'] as bool? ?? true,
        draftMinutes: j['draftMinutes'] as int? ?? 15,
      );
}

/// Bridge to the Kotlin side (MainActivity / UsageReader / MiraWorker).
/// Every call degrades gracefully when the platform code is missing
/// (e.g. in tests or on non-Android builds).
class ScreenTimeService {
  static const _ch = MethodChannel('mira/native');

  void Function(String action)? onLaunchAction;

  ScreenTimeService() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'launchAction') onLaunchAction?.call(call.arguments as String);
    });
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> hasUsagePermission() async =>
      await _call<bool>('hasUsagePermission') ?? false;

  Future<void> openUsageSettings() => _call('openUsageSettings');

  Future<bool> hasNotificationPermission() async =>
      await _call<bool>('hasNotificationPermission') ?? false;

  Future<void> requestNotificationPermission() =>
      _call('requestNotificationPermission');

  Future<UsageSummary?> today() async {
    final now = DateTime.now();
    final m = await _call<Map>('getUsage', {
      'start': DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
      'end': now.millisecondsSinceEpoch,
    });
    return m == null ? null : UsageSummary.fromMap(m);
  }

  /// Long social/video/game sessions between [start] and [end].
  Future<List<DetectedSession>> episodes(DateTime start, DateTime end,
      {int minMinutes = 15}) async {
    final l = await _call<List>('getEpisodes', {
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
      'minMinutes': minMinutes,
    });
    return l == null ? [] : l.map((m) => DetectedSession.fromMap(m as Map)).toList();
  }

  /// One summary per day, oldest first, ending today.
  Future<List<UsageSummary>> daily({int days = 7}) async {
    final l = await _call<List>('getDailyUsage', {'days': days});
    return l == null ? [] : l.map((m) => UsageSummary.fromMap(m as Map)).toList();
  }

  Future<void> pushSettings(NudgeSettings s) =>
      _call('setConfig', {'json': jsonEncode({...s.toJson(), 'petName': 'Mira'})});

  Future<void> markLogged(DateTime day) =>
      _call('markLogged', {'day': DateFormat('yyyy-MM-dd').format(day)});

  Future<String?> takeLaunchAction() => _call<String>('takeLaunchAction');

  /// Posts a sample warning, for demos and checking notification settings.
  Future<void> testNudge() => _call('testNudge');

  /// Runs the background check once right now instead of waiting ~15 min.
  Future<void> checkNow() => _call('checkNow');
}

String formatMinutes(num minutes) {
  final m = minutes.round();
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}
