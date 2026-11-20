import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/chat_context.dart';
import 'package:psu_second_brain/services/companion_ai.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/screen_time.dart';

final now = DateTime(2026, 11, 21, 22, 15);

UsageSummary today() => UsageSummary.fromMap({
      'totalMinutes': 300.0, 'socialMinutes': 120.0, 'videoMinutes': 60.0,
      'gamesMinutes': 0.0, 'chatMinutes': 20.0, 'audioMinutes': 10.0,
      'unlocks': 33, 'opens': 80, 'lateNightMinutes': 15.0,
      'longestSessionMinutes': 50.0, 'longestSessionApp': 'TikTok',
      'apps': [
        {'package': 'com.zhiliaoapp.musically', 'label': 'TikTok', 'group': 'social', 'minutes': 120.0, 'opens': 30},
        {'package': 'com.google.android.youtube', 'label': 'YouTube', 'group': 'video', 'minutes': 60.0, 'opens': 9},
        {'package': 'ai.x.grok', 'label': 'Grok', 'group': 'other', 'minutes': 90.0, 'opens': 5},
        {'package': 'com.twitter.android', 'label': 'X', 'group': 'social', 'minutes': 0.5, 'opens': 1},
      ],
    });

final logs = [
  LogEntry(id: 'a', timestamp: DateTime(2026, 11, 21, 21, 40), kind: EntryKind.episode,
      mood: 2, stress: 4, craving: 4, durationMinutes: 40, triggers: [Trigger.boredom],
      note: 'my secret note about Ali', appPackage: 'com.zhiliaoapp.musically',
      appLabel: 'TikTok', appGroup: 'social', draftId: 'com.zhiliaoapp.musically@1'),
  LogEntry(id: 'b', timestamp: DateTime(2026, 11, 20, 23, 30), kind: EntryKind.checkIn,
      mood: 3, stress: 3, craving: 2, note: 'another private thing'),
  LogEntry(id: 'c', timestamp: DateTime(2026, 11, 19, 14, 0), kind: EntryKind.episode,
      mood: 4, stress: 2, craving: 2, durationMinutes: 15, resisted: true,
      triggers: [Trigger.stress]),
  LogEntry(id: 'd', timestamp: DateTime(2026, 11, 10, 9, 0), kind: EntryKind.episode,
      mood: 3, stress: 3, craving: 3, durationMinutes: 5),
];

PromptScrubber scrubber() => PromptScrubber(displayName: 'Mary', appGroups: {
      for (final a in today().apps) a.label: a.group,
      'TikTok': 'social',
    });

Map<String, dynamic> context() {
  final f = BehaviourFeatures.fromLogs(logs, now: now);
  return buildChatContext(
    now: now,
    features: f,
    risk: RiskResult(RiskLevel.medium, 0.5, ['About 5.0h of screen time a day'], 'test'),
    logs: logs,
    today: today(),
  );
}

void main() {
  test('nothing identifying leaves the phone: no names, app names, notes or IDs', () {
    final history = [
      ChatMessage(fromUser: true, text: 'You noticed I spent 40 min on TikTok (boredom), about '
          '40 min. Mood 2/5, stress 4/5, urge 4/5. Note: my secret note about Ali'),
      ChatMessage(fromUser: false, text: 'Hi Mary! TikTok again huh?'),
      ChatMessage(fromUser: true, text: 'I am Mary and I was on youtube and Grok all night'),
    ];
    final (system, messages) = CompanionAI.chatPrompt(
      userText: 'Watched YouTube then TikTok, ugh',
      context: context(),
      history: history,
      scrubber: scrubber(),
    );
    final sent = [system, for (final (_, t) in messages) t].join('\n');
    for (final secret in [
      'TikTok', 'YouTube', 'youtube', 'Grok', 'Mary', 'secret note', 'private thing',
      'Ali', 'com.zhiliaoapp', 'com.google', 'draft', 'musically',
    ]) {
      expect(sent, isNot(contains(secret)), reason: secret);
    }
    expect(sent, contains('a social app'));
    expect(sent, contains('a video app'));
    expect(messages.last.$2, 'Watched a video app then a social app, ugh');
    expect(messages.first.$2, endsWith('urge 4/5.'));
  });

  test('context carries today, 7-day averages, risk and the last 3 logs', () {
    final c = context();
    expect(c['now'], 'Sat 22:15');
    expect(c['current_risk_level'], 'Medium');
    final t = c['today_minutes'] as Map<String, dynamic>;
    expect(t['screen_time'], 290); // 300 total minus 10 audio
    expect(t['social'], 120);
    expect(t['other'], 90);
    expect(t['unlocks'], 33);
    final recent = (c['recent_logs'] as List).cast<Map<String, dynamic>>();
    expect(recent, hasLength(3));
    expect(recent.map((l) => l['when']), ['today 21:40', 'yesterday 23:30', '2 days ago 14:00']);
    expect(recent.first['app'], 'a social app');
    expect(recent.first['outcome'], 'continued');
    expect(recent.first['triggers'], ['boredom']);
    expect(recent[1]['kind'], 'check-in');
    expect(recent[1].containsKey('minutes'), isFalse);
    expect(recent[2]['outcome'], 'resisted');
    expect(jsonEncode(c), isNot(contains('note')));
    expect(c.containsKey('last_7_days'), isTrue);
  });

  test('without screen time there is no today block', () {
    final c = buildChatContext(
        now: now,
        features: BehaviourFeatures.fromLogs(logs, now: now),
        risk: RiskResult(RiskLevel.low, 0, [], 'h'),
        logs: logs);
    expect(c.containsKey('today_minutes'), isFalse);
  });

  test('scrubbing respects word boundaries and skips one-letter labels', () {
    final s = PromptScrubber(displayName: 'Mary', appGroups: {'X': 'social', 'Chrome': 'other'});
    expect(s.scrub('Maryland is far, Mary'), 'Maryland is far, the user');
    expect(s.scrub('X and Xbox in chrome'), 'X and Xbox in an app');
    expect(s.scrub('My note: keep it'), 'My note: keep it'); // only log reactions lose notes
  });

  test('only the last 8 turns are sent', () {
    final history = [for (var i = 0; i < 12; i++) ChatMessage(fromUser: i.isEven, text: 'm$i')];
    final (_, messages) =
        CompanionAI.chatPrompt(userText: 'hi', context: const {}, history: history);
    expect(messages, hasLength(9));
    expect(messages.first.$2, 'm4');
  });

  test('the crisis filter still checks the user\'s own words first', () async {
    final ai = CompanionAI(proxyUrl: '');
    final r = await ai.reply(
      userText: 'Mary here, I want to die',
      features: BehaviourFeatures.fromLogs([]),
      risk: RiskResult(RiskLevel.low, 0, [], 'h'),
      history: [],
      context: const {},
      scrubber: scrubber(),
    );
    expect(r.text, CompanionAI.crisisMessage);
  });
}
