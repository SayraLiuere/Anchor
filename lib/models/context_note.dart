import 'package:flutter/material.dart';

import 'timestamps.dart';

/// What a context note is about (C3, FR18, thesis 3.5.7).
enum NoteType {
  health('health', 'Health', Icons.healing_outlined),
  mood('mood', 'Mood', Icons.mood_outlined),
  blockFeedback('block_feedback', 'Block', Icons.rate_review_outlined),
  plan('plan', 'Plan', Icons.event_note_outlined);

  const NoteType(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;

  static NoteType fromId(String? id) =>
      values.firstWhere((t) => t.id == id, orElse: () => mood);
}

/// A note about today (or one block today), stored in `context_notes`:
/// {id, date, block_id?, type, label, private, source}. Health notes are
/// always private: later prompts only say one exists.
class ContextNote {
  ContextNote({
    required this.id,
    required this.date,
    required this.type,
    required this.label,
    this.blockId,
    bool private = false,
    this.source = 'chat',
    this.until,
  }) : private = private || type == NoteType.health;

  /// For a gentle evening: when its pause on limit warnings ends, fixed
  /// when the note is added (see [gentleEveningEnds]).
  final DateTime? until;

  final String id;

  /// Local date `yyyy-MM-dd`.
  final String date;
  final String? blockId;
  final NoteType type;
  final String label;
  final bool private;

  /// `chat` (from Mira) or `manual`.
  final String source;

  /// A plan to take it easy tonight: limit warnings pause until morning.
  bool get isGentleEvening =>
      type == NoteType.plan && label.toLowerCase().contains('gentle evening');

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        if (blockId != null) 'block_id': blockId,
        'type': type.id,
        'label': label,
        'private': private,
        'source': source,
        if (until != null) 'until': toOffsetIso(until!),
      };

  factory ContextNote.fromJson(Map<String, dynamic> j) => ContextNote(
        id: j['id'] as String,
        date: j['date'] as String,
        blockId: j['block_id'] as String?,
        type: NoteType.fromId(j['type'] as String?),
        label: j['label'] as String? ?? '',
        private: j['private'] as bool? ?? false,
        source: j['source'] as String? ?? 'chat',
        until: j['until'] == null ? null : parseTimestamp(j['until'] as String),
      );
}

/// A note Mira suggested; saved only when the user ticks it and taps Add.
class SuggestedNote {
  SuggestedNote(this.label, this.type, {this.forBlock = false});

  final String label;
  final NoteType type;

  /// Scope "block": attach to the block running when it is added.
  final bool forBlock;
}

/// When a gentle evening set at [t] ends: 06:00 the next morning, or 06:00
/// today if it is set after midnight ("tonight" then means this night).
DateTime gentleEveningEnds(DateTime t) => t.hour < 6
    ? DateTime(t.year, t.month, t.day, 6)
    : DateTime(t.year, t.month, t.day + 1, 6);

/// The latest end of a gentle evening still running at [now], or null.
DateTime? warningsPausedUntil(List<ContextNote> notes, DateTime now) {
  DateTime? latest;
  for (final n in notes.where((n) => n.isGentleEvening)) {
    // Notes saved without an end (none yet) count until 06:00 after their date.
    final end = n.until ?? gentleEveningEnds(DateTime.parse(n.date).add(const Duration(hours: 12)));
    if (end.isAfter(now) && (latest == null || end.isAfter(latest))) latest = end;
  }
  return latest;
}
