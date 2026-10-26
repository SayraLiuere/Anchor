import 'package:flutter/material.dart';

/// Trigger categories from Table 4.3 of the thesis, plus "urge" which backs
/// the notification/urge indicator in Table 3.1.
enum Trigger {
  boredom('Boredom', Icons.hourglass_empty),
  stress('Stress', Icons.bolt),
  avoidance('Avoidance', Icons.directions_run),
  reward('Reward-seeking', Icons.card_giftcard),
  lateNight('Late-night', Icons.bedtime),
  urge('Notification / urge', Icons.notifications_active),
  other('Other', Icons.more_horiz);

  const Trigger(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum EntryKind { episode, checkIn }

/// One record in the behavioural memory (thesis Table 4.3).
class LogEntry {
  LogEntry({
    required this.id,
    required this.timestamp,
    required this.kind,
    required this.mood,
    required this.stress,
    required this.craving,
    this.triggers = const [],
    this.durationMinutes = 0,
    this.resisted = false,
    this.note = '',
    this.synthetic = false,
    this.appPackage,
    this.appLabel,
    this.draftId,
  });

  final String id;
  final DateTime timestamp;
  final EntryKind kind;

  /// 1 (very low) – 5 (very good)
  final int mood;

  /// 1 (calm) – 5 (very stressed)
  final int stress;

  /// 1 (no urge) – 5 (strong urge to check)
  final int craving;
  final List<Trigger> triggers;
  final int durationMinutes;
  final bool resisted;
  final String note;

  /// Marks simulated records (thesis 3.4.6) so they never mix with real data.
  final bool synthetic;

  /// Set when the episode came from an auto-detected session (draft).
  final String? appPackage;
  final String? appLabel;
  final String? draftId;

  bool get autoDetected => draftId != null;

  bool get isLateNight => timestamp.hour >= 23 || timestamp.hour < 5;

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'kind': kind.name,
        'mood_rating': mood,
        'perceived_stress': stress,
        'craving_intensity': craving,
        'trigger_category': triggers.map((t) => t.name).toList(),
        'perceived_duration': durationMinutes,
        'continued_or_resisted': resisted ? 'resisted' : 'continued',
        'context_note': note,
        'synthetic': synthetic,
        if (appPackage != null) 'app_package': appPackage,
        if (appLabel != null) 'app_label': appLabel,
        if (draftId != null) 'draft_id': draftId,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        kind: EntryKind.values.byName(j['kind'] as String),
        mood: j['mood_rating'] as int,
        stress: j['perceived_stress'] as int,
        craving: j['craving_intensity'] as int,
        triggers: (j['trigger_category'] as List)
            .map((t) => Trigger.values.byName(t as String))
            .toList(),
        durationMinutes: j['perceived_duration'] as int? ?? 0,
        resisted: j['continued_or_resisted'] == 'resisted',
        note: j['context_note'] as String? ?? '',
        synthetic: j['synthetic'] as bool? ?? false,
        appPackage: j['app_package'] as String?,
        appLabel: j['app_label'] as String?,
        draftId: j['draft_id'] as String?,
      );
}

class ChatMessage {
  ChatMessage({required this.fromUser, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  final bool fromUser;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'fromUser': fromUser, 'text': text, 'at': at.toIso8601String()};

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        fromUser: j['fromUser'] as bool,
        text: j['text'] as String,
        at: DateTime.parse(j['at'] as String),
      );
}
