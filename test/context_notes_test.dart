import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/context_note.dart';
import 'package:psu_second_brain/services/chat_context.dart';
import 'package:psu_second_brain/services/companion_ai.dart';
import 'package:psu_second_brain/services/memory.dart';

/// What Mira returns for the wireframe's period-day message.
final periodDay = jsonEncode({
  'reply': 'Aw, sending you a warm hug. A slow, cosy evening sounds perfect.',
  'facts': [],
  'notes': [
    {'label': 'Period cramps', 'type': 'health', 'scope': 'day'},
    {'label': 'Gentle evening', 'type': 'plan', 'scope': 'day'},
  ],
});

List<ContextNote> save(List<SuggestedNote> chosen) => [
      for (final (i, s) in chosen.indexed)
        ContextNote(id: '$i', date: '2026-11-21', type: s.type, label: s.label),
    ];

void main() {
  test('the period-day example gives two notes, saved as two chips', () {
    final r = parseMiraResponse(periodDay);
    expect(r.notes.map((n) => (n.label, n.type)), [
      ('Period cramps', NoteType.health),
      ('Gentle evening', NoteType.plan),
    ]);
    final saved = save(r.notes);
    expect(saved, hasLength(2));
    expect(saved.first.private, isTrue); // health is always private
    expect(saved.last.private, isFalse);
    expect(saved.last.isGentleEvening, isTrue);
  });

  test('the next prompt has no health details, only that a note exists', () {
    final notes = save(parseMiraResponse(periodDay).notes);
    final (system, messages) = CompanionAI.chatPrompt(
      userText: 'still a bit sore',
      context: {'today_notes': notesForPrompt(notes, PromptScrubber())},
      history: const [],
    );
    final sent = [system, for (final (_, t) in messages) t].join('\n');
    expect(sent, contains('Gentle evening'));
    expect(sent, contains('1 private health note(s) exist'));
    for (final secret in ['Period cramps', 'cramps', 'Period day']) {
      expect(sent, isNot(contains(secret)), reason: secret);
    }
  });

  test('block notes, caps and bad entries', () {
    final r = parseMiraResponse(jsonEncode({
      'reply': 'ok',
      'notes': [
        {'label': 'Draining class', 'type': 'block_feedback', 'scope': 'block'},
        {'label': '', 'type': 'mood'},
        {'type': 'mood'},
        {'label': 'Exam nerves', 'type': 'mood', 'scope': 'day'},
        {'label': 'Tired', 'type': 'mood'},
        {'label': 'Fourth', 'type': 'mood'},
      ],
    }));
    expect(r.notes.map((n) => n.label), ['Draining class', 'Exam nerves', 'Tired']);
    expect(r.notes.first.forBlock, isTrue);
    expect(r.notes[1].forBlock, isFalse);
    expect(parseMiraResponse('{"reply": "hi"}').notes, isEmpty);
  });

  test('a gentle evening pauses warnings until the next 06:00', () {
    expect(gentleEveningEnds(DateTime(2026, 11, 21, 19)), DateTime(2026, 11, 22, 6));
    expect(gentleEveningEnds(DateTime(2026, 11, 30, 23)), DateTime(2026, 12, 1, 6));
    // Said after midnight, "tonight" means until 06:00 this morning.
    expect(gentleEveningEnds(DateTime(2026, 11, 21, 1)), DateTime(2026, 11, 21, 6));
    final other = ContextNote(id: 'x', date: '2026-11-21', type: NoteType.plan, label: 'Study group');
    expect(other.isGentleEvening, isFalse);
  });

  test('notes round-trip through JSON; health stays private on load', () {
    final n = ContextNote(
        id: 'a', date: '2026-11-21', type: NoteType.blockFeedback, label: 'Draining class', blockId: 'lec');
    expect(ContextNote.fromJson(n.toJson()).toJson(), n.toJson());
    final tampered = ContextNote.fromJson(
        {'id': 'h', 'date': '2026-11-21', 'type': 'health', 'label': 'Migraine', 'private': false});
    expect(tampered.private, isTrue);
  });

  test('note labels are scrubbed of names and app names', () {
    final p = notesForPrompt(
        [ContextNote(id: 'm', date: '2026-11-21', type: NoteType.mood, label: 'Fight with Ali on WhatsApp')],
        PromptScrubber(displayName: 'Ali', appGroups: {'WhatsApp': 'chat'}));
    expect(jsonEncode(p), contains('Fight with the user on a messaging app'));
  });
}


