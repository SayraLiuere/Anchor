import 'dart:math';

import 'package:intl/intl.dart';

import '../models/log_entry.dart';
import '../models/schedule_block.dart';
import 'features.dart';
import 'risk_model.dart';
import 'schedule_service.dart';
import 'screen_time.dart';

/// What the AI is told instead of an app's name (B2, ground rule 3).
String groupPhrase(String? group) => switch (group) {
      'social' => 'a social app',
      'video' => 'a video app',
      'games' => 'a game',
      'chat' => 'a messaging app',
      'audio' => 'a music app',
      _ => 'an app',
    };

double _r(double x) => (x * 10).roundToDouble() / 10;

/// Structured, identifier-free context for Mira's chat (B2, FR5, thesis
/// 5.3.3): today's minutes per category, 7-day averages, risk and reasons,
/// and the last 3 logs. Numbers and categories only: no names, app names,
/// IDs or note text.
Map<String, dynamic> buildChatContext({
  required DateTime now,
  required BehaviourFeatures features,
  required RiskResult risk,
  required List<LogEntry> logs,
  UsageSummary? today,
  ScheduleService? schedule,
}) {
  final recent = [...logs]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return {
    'now': DateFormat('EEE HH:mm').format(now),
    'current_risk_level': risk.level.label,
    'risk_reasons': risk.reasons,
    if (schedule != null && schedule.blocks.isNotEmpty) 'schedule_today': _schedule(schedule, now),
    if (today != null) 'today_minutes': _today(today),
    'last_7_days': features.toPromptJson(),
    'recent_logs': [for (final l in recent.take(3)) _log(l, now)],
  };
}

/// Today's blocks by type and time (C1). Titles are typed by the user, so
/// they are never sent.
Map<String, dynamic> _schedule(ScheduleService s, DateTime now) {
  final current = s.currentBlock(now);
  final load = s.todayLoad(now);
  String hm(DateTime t) => DateFormat('HH:mm').format(t);
  return {
    'right_now': current == null
        ? 'nothing scheduled'
        : current.type == BlockType.folder
            ? 'free time between scheduled blocks'
            : current.type.id,
    'day_load': load.label.label.toLowerCase(),
    'blocks': [
      for (final o in s.occurrencesOn(now))
        if (o.block.type != BlockType.folder)
          {'type': o.block.type.id, 'from': hm(o.start), 'to': hm(o.end)},
    ],
  };
}

Map<String, dynamic> _today(UsageSummary t) {
  final named = t.socialMinutes + t.videoMinutes + t.gamesMinutes + t.chatMinutes + t.audioMinutes;
  return {
    'screen_time': _r(t.screenMinutes),
    'social': _r(t.socialMinutes),
    'video': _r(t.videoMinutes),
    'games': _r(t.gamesMinutes),
    'messaging': _r(t.chatMinutes),
    'music_podcasts_not_counted': _r(t.audioMinutes),
    'other': _r(max(0, t.totalMinutes - named)),
    'late_night': _r(t.lateNightMinutes),
    'unlocks': t.unlocks,
  };
}

Map<String, dynamic> _log(LogEntry l, DateTime now) {
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(l.timestamp.year, l.timestamp.month, l.timestamp.day))
      .inDays;
  return {
    'when': '${days == 0 ? 'today' : days == 1 ? 'yesterday' : '$days days ago'} '
        '${DateFormat('HH:mm').format(l.timestamp)}',
    'kind': l.kind == EntryKind.episode ? 'episode' : 'check-in',
    'triggers': [for (final t in l.triggers) t.label.toLowerCase()],
    'mood_1to5': l.mood,
    'stress_1to5': l.stress,
    'urge_1to5': l.craving,
    if (l.kind == EntryKind.episode) ...{
      'minutes': l.durationMinutes,
      'outcome': l.resisted ? 'resisted' : 'continued',
      if (l.appGroup != null || l.appLabel != null) 'app': groupPhrase(l.appGroup),
    },
  };
}

/// Removes identifiers from text before it is sent to the AI (B2). Used on
/// the user's message and on the chat history, which can hold older
/// messages written before this existed.
class PromptScrubber {
  PromptScrubber({String displayName = '', Map<String, String?> appGroups = const {}})
      : _name = displayName.trim().length >= 2 ? _word(displayName.trim()) : null,
        // Longest first, so "YouTube Music" wins over "YouTube". One-letter
        // labels (e.g. "X") are skipped: they would mangle ordinary text.
        _apps = (appGroups.entries.where((e) => e.key.trim().length >= 2).toList()
              ..sort((a, b) => b.key.length.compareTo(a.key.length)))
            .map((e) => (_word(e.key.trim()), groupPhrase(e.value)))
            .toList();

  final RegExp? _name;
  final List<(RegExp, String)> _apps;

  static RegExp _word(String s) =>
      RegExp('(?<![\\w])${RegExp.escape(s)}(?![\\w])', caseSensitive: false);

  /// Log reactions used to end with "Note: ..." (the log's note); notes are private.
  static final _reaction = RegExp(r'^(Quick check-in|You noticed I spent|I just logged a phone episode)');
  static final _note = RegExp(r'\s*Note: .*$', dotAll: true);

  String scrub(String text) {
    var t = _reaction.hasMatch(text) ? text.replaceFirst(_note, '') : text;
    for (final (re, phrase) in _apps) {
      t = t.replaceAll(re, phrase);
    }
    if (_name != null) t = t.replaceAll(_name, 'the user');
    return t;
  }
}

double _h(double minutes) => (minutes / 6).roundToDouble() / 10;

/// Context for the weekly recap (B3, FR5): the same identifier-free data as
/// chat, plus a day-by-day table and the risk model's result. Built from
/// numbers only; nothing the user typed is in it.
Map<String, dynamic> buildRecapContext({
  required DateTime now,
  required BehaviourFeatures features,
  required RiskResult risk,
  required List<UsageSummary> week,
}) {
  final today = DateTime(now.year, now.month, now.day);
  return {
    'report_date': DateFormat('EEE d MMM yyyy').format(now),
    'risk': {
      'level': risk.level.label,
      'model': risk.modelName,
      'estimated_probability_percent': (risk.score * 100).round(),
      'reasons': risk.reasons,
      'note': 'A screening estimate from a model trained on survey data, '
          'not a diagnosis. Describe it in plain words.',
    },
    if (week.isNotEmpty)
      'screen_time_by_day': [
        for (final d in week)
          {
            'day': d.dayStart == null
                ? '?'
                : DateFormat('EEE d MMM').format(d.dayStart!) +
                    (DateTime(d.dayStart!.year, d.dayStart!.month, d.dayStart!.day) == today
                        ? ' (today so far)'
                        : ''),
            'screen_hours': _h(d.screenMinutes),
            'social_hours': _h(d.socialMinutes),
            'video_hours': _h(d.videoMinutes),
            'games_hours': _h(d.gamesMinutes),
            'late_night_hours': _h(d.lateNightMinutes),
            'unlocks': d.unlocks,
          },
      ],
    'last_7_days': features.toPromptJson(),
  };
}
