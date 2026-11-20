import 'dart:convert';

import '../models/fact.dart';
import '../models/log_entry.dart';
import 'chat_context.dart' show PromptScrubber;

/// Mira's answer, split into what to show and what she suggests saving.
class MiraReply {
  MiraReply(this.text, {this.facts = const [], this.notes = const []});

  final String text;
  final List<SuggestedFact> facts;

  /// Context notes for C3; parsed now, used once C3 exists.
  final List<Map<String, dynamic>> notes;
}

/// The AI is asked for {reply, notes[], facts[]} (B4). Anything that is not
/// that JSON (a plain-text reply, a template, a broken object) is shown as
/// the reply, so nothing is ever lost.
MiraReply parseMiraResponse(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return MiraReply(raw.trim());
  try {
    final j = jsonDecode(raw.substring(start, end + 1));
    if (j is! Map || j['reply'] is! String || (j['reply'] as String).trim().isEmpty) {
      return MiraReply(raw.trim());
    }
    final facts = <SuggestedFact>[
      for (final f in (j['facts'] as List? ?? const []))
        if (f is Map && f['text'] is String && (f['text'] as String).trim().isNotEmpty)
          SuggestedFact(
            (f['text'] as String).trim(),
            FactCategory.fromId(f['category'] as String?),
            private: f['private'] == true,
          ),
    ];
    return MiraReply(
      (j['reply'] as String).trim(),
      // At most two suggestions per reply, so the chat never fills with cards.
      facts: facts.take(2).toList(),
      notes: [for (final n in (j['notes'] as List? ?? const [])) if (n is Map) Map<String, dynamic>.from(n)],
    );
  } catch (_) {
    return MiraReply(raw.trim());
  }
}

/// Words that tie a fact to the current moment, used to rank relevance.
const _triggerWords = {
  Trigger.boredom: ['bored', 'boredom', 'nothing to do'],
  Trigger.stress: ['stress', 'stressed', 'exam', 'deadline', 'pressure', 'assignment'],
  Trigger.avoidance: ['avoid', 'procrastinat', 'putting off'],
  Trigger.reward: ['reward', 'treat', 'after finishing'],
  Trigger.lateNight: ['night', 'bed', 'sleep', 'late'],
  Trigger.urge: ['notification', 'urge', 'check'],
  Trigger.other: <String>[],
};

List<String> _hourWords(int h) => h < 5 || h >= 23
    ? ['night', 'late', 'bed', 'sleep']
    : h < 12
        ? ['morning', 'wake', 'breakfast']
        : h < 18
            ? ['afternoon', 'lunch', 'after class']
            : ['evening', 'dinner', 'night'];

List<String> _blockWords(String? block) => switch (block) {
      'class' => ['class', 'lecture', 'tutorial', 'lab'],
      'study' => ['study', 'studying', 'revision', 'revise', 'assignment'],
      'work' => ['work', 'shift', 'job'],
      'sleep' => ['sleep', 'bed', 'night'],
      'break' => ['break', 'rest', 'lunch'],
      'folder' => ['campus', 'free time', 'between classes'],
      _ => <String>[],
    };

/// The [max] facts most relevant now (B4): those matching the current
/// trigger, block or time of day first, then the most recently confirmed.
List<Fact> selectFacts(
  List<Fact> facts, {
  required DateTime now,
  Trigger? trigger,
  String? blockType,
  int max = 15,
}) {
  final words = [
    ...?_triggerWords[trigger],
    ..._blockWords(blockType),
    ..._hourWords(now.hour),
  ];
  int score(Fact f) {
    final t = f.text.toLowerCase();
    return words.where(t.contains).length;
  }

  final ranked = [...facts]..sort((a, b) {
      final s = score(b).compareTo(score(a));
      return s != 0 ? s : b.lastConfirmed.compareTo(a.lastConfirmed);
    });
  return ranked.take(max).toList();
}

/// What the AI sees of the selected facts: text and category, scrubbed of
/// names and app names. Private facts are only counted, never shown.
Map<String, dynamic> factsForPrompt(List<Fact> selected, PromptScrubber scrubber) {
  final open = selected.where((f) => !f.private).toList();
  final private = selected.length - open.length;
  return {
    'things_the_user_confirmed': [
      for (final f in open) {'category': f.category.id, 'fact': scrubber.scrub(f.text)},
    ],
    if (private > 0) 'private_health_notes': '$private private health note(s) exist; details are not shared',
  };
}

/// Instructions for the JSON answer, added after the persona (B4). The
/// persona and safety rules themselves are unchanged.
const memoryInstructions = '''
Answer format: reply with ONLY a JSON object, no other text:
{"reply": "<your message to the user>", "notes": [], "facts": []}
"facts": usually empty. Add one only when the user states something lasting about themselves that would help you support them later: what helps them, what triggers their phone use, a preference, or a recurring pattern. Each fact: {"text": "<max 15 words, about the user, e.g. 'Feels restless after long lectures'>", "category": "what_helps" | "trigger" | "preference" | "pattern", "private": <true for health, medical or mental-health details, else false>}.
Never suggest a fact that is already in things_the_user_confirmed. Use those facts naturally when they fit.
"notes": always an empty list for now.''';
