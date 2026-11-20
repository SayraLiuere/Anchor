import 'package:flutter/material.dart';

import 'timestamps.dart';

/// What a remembered fact is about (B4, FR22-FR24, thesis 3.5.10).
enum FactCategory {
  preference('preference', 'Preference', Icons.favorite_border),
  trigger('trigger', 'Trigger', Icons.bolt),
  whatHelps('what_helps', 'What helps', Icons.spa_outlined),
  pattern('pattern', 'Pattern', Icons.timeline);

  const FactCategory(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;

  static FactCategory fromId(String? id) =>
      values.firstWhere((c) => c.id == id, orElse: () => pattern);
}

/// Where a fact came from.
enum FactSource { chat, rating, weekly, manual }

/// Something Mira remembers about the user, stored in `facts`:
/// {id, text, category, source, private, created_at, last_confirmed,
/// times_helped}. Only saved after the user taps to confirm it.
class Fact {
  Fact({
    required this.id,
    required this.text,
    required this.category,
    this.source = FactSource.chat,
    this.private = false,
    required this.createdAt,
    DateTime? lastConfirmed,
    this.timesHelped = 0,
  }) : lastConfirmed = lastConfirmed ?? createdAt;

  final String id;
  final String text;
  final FactCategory category;
  final FactSource source;

  /// Health and other sensitive facts: the AI is only told one exists.
  final bool private;
  final DateTime createdAt;
  final DateTime lastConfirmed;
  final int timesHelped;

  Fact copyWith({String? text, FactCategory? category, bool? private, DateTime? lastConfirmed}) =>
      Fact(
        id: id,
        text: text ?? this.text,
        category: category ?? this.category,
        source: source,
        private: private ?? this.private,
        createdAt: createdAt,
        lastConfirmed: lastConfirmed ?? this.lastConfirmed,
        timesHelped: timesHelped,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'category': category.id,
        'source': source.name,
        'private': private,
        'created_at': toOffsetIso(createdAt),
        'last_confirmed': toOffsetIso(lastConfirmed),
        'times_helped': timesHelped,
      };

  factory Fact.fromJson(Map<String, dynamic> j) => Fact(
        id: j['id'] as String,
        text: j['text'] as String? ?? '',
        category: FactCategory.fromId(j['category'] as String?),
        source: FactSource.values.asNameMap()[j['source']] ?? FactSource.chat,
        private: j['private'] as bool? ?? false,
        createdAt: parseTimestamp(j['created_at'] as String),
        lastConfirmed: j['last_confirmed'] == null
            ? null
            : parseTimestamp(j['last_confirmed'] as String),
        timesHelped: (j['times_helped'] as num?)?.toInt() ?? 0,
      );
}

/// A fact the AI suggested; it becomes a [Fact] only when the user confirms.
class SuggestedFact {
  SuggestedFact(this.text, this.category, {this.private = false});

  final String text;
  final FactCategory category;
  final bool private;
}
