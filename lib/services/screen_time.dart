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

/// Limits and reminders, enforced by the native background watcher.
class NudgeSettings {
  NudgeSettings({
    this.warningsEnabled = true,
    Map<String, int>? limits,
    this.sessionMinutes = 30,
    this.logReminder = true,
    this.reminderHour = 21,
  }) : limits = limits ?? {'social': 60, 'games': 60, 'video': 90, 'total': 300};

  bool warningsEnabled;
  Map<String, int> limits;
  int sessionMinutes;
  bool logReminder;
  int reminderHour;

  Map<String, dynamic> toJson() => {
        'warningsEnabled': warningsEnabled,
        'limits': limits,
        'sessionMinutes': sessionMinutes,
        'logReminder': logReminder,
        'reminderHour': reminderHour,
      };

  factory NudgeSettings.fromJson(Map<String, dynamic> j) => NudgeSettings(
        warningsEnabled: j['warningsEnabled'] as bool? ?? true,
        limits: (j['limits'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, v as int)),
        sessionMinutes: j['sessionMinutes'] as int? ?? 30,
        logReminder: j['logReminder'] as bool? ?? true,
        reminderHour: j['reminderHour'] as int? ?? 21,
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
