import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:psu_second_brain/models/fact.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/chat_context.dart';
import 'package:psu_second_brain/services/companion_ai.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/memory.dart';
import 'package:psu_second_brain/services/risk_model.dart';

Fact fact(String id, String text,
        {FactCategory c = FactCategory.whatHelps, bool private = false, int daysAgo = 0}) =>
    Fact(
      id: id,
      text: text,
      category: c,
      private: private,
      createdAt: DateTime(2026, 11, 20).subtract(Duration(days: daysAgo)),
    );

void main() {
  group('parsing Mira\'s answer', () {
    test('JSON with a suggested fact', () {
      final r = parseMiraResponse(jsonEncode({
        'reply': 'A walk sounds perfect!',
        'notes': [],
        'facts': [
          {'text': 'A short walk helps when stressed', 'category': 'what_helps', 'private': false}
        ],
      }));
      expect(r.text, 'A walk sounds perfect!');
      expect(r.facts.single.text, 'A short walk helps when stressed');
      expect(r.facts.single.category, FactCategory.whatHelps);
      expect(r.facts.single.private, isFalse);
    });

    test('code fences and text around the JSON are tolerated', () {
      final r = parseMiraResponse('```json\n{"reply": "hey!", "facts": [{"text": "Period cramps make '
          'scrolling worse", "category": "trigger", "private": true}]}\n```');
      expect(r.text, 'hey!');
      expect(r.facts.single.private, isTrue);
      expect(r.facts.single.category, FactCategory.trigger);
    });

    test('anything else is shown as the reply, nothing lost', () {
      expect(parseMiraResponse('Just a normal reply :)').text, 'Just a normal reply :)');
      expect(parseMiraResponse('{"reply": broken').text, '{"reply": broken');
      expect(parseMiraResponse('{"answer": "no reply key"}').text, '{"answer": "no reply key"}');
      expect(parseMiraResponse('{"reply": "hi", "facts": "oops"}').facts, isEmpty);
    });

    test('at most two suggestions; empty ones are dropped', () {
      final r = parseMiraResponse(jsonEncode({
        'reply': 'ok',
        'facts': [
          {'text': ''},
          for (var i = 0; i < 4; i++) {'text': 'fact $i', 'category': 'pattern'},
        ],
      }));
      expect(r.facts.map((f) => f.text), ['fact 0', 'fact 1']);
    });
  });

  group('choosing facts for the prompt', () {
    final facts = [
      fact('a', 'Music helps me focus', daysAgo: 1),
      fact('b', 'A short walk helps when stressed', daysAgo: 9),
      fact('c', 'Scrolls in bed late at night', c: FactCategory.pattern, daysAgo: 5),
      fact('d', 'Gets bored between classes', c: FactCategory.trigger, daysAgo: 3),
    ];

    test('the current trigger ranks first, then newest', () {
      final s = selectFacts(facts, now: DateTime(2026, 11, 20, 15), trigger: Trigger.stress);
      expect(s.first.id, 'b');
      expect(s.map((f) => f.id).skip(1), ['a', 'd', 'c']); // the rest by newest
    });

    test('the current block and time of day count too', () {
      expect(selectFacts(facts, now: DateTime(2026, 11, 20, 12), blockType: 'folder').first.id, 'd');
      expect(selectFacts(facts, now: DateTime(2026, 11, 20, 23, 30)).first.id, 'c');
    });

    test('at most 15 facts', () {
      final many = [for (var i = 0; i < 30; i++) fact('$i', 'fact $i', daysAgo: i)];
      final s = selectFacts(many, now: DateTime(2026, 11, 20, 10));
      expect(s, hasLength(15));
      expect(s.first.id, '0');
    });

    test('private facts are only counted; text is scrubbed', () {
      final p = factsForPrompt([
        fact('x', 'Watching TikTok helps Mary wind down'),
        fact('y', 'Has anxiety medication at night', private: true),
      ], PromptScrubber(displayName: 'Mary', appGroups: {'TikTok': 'social'}));
      final text = jsonEncode(p);
      expect(text, contains('Watching a social app helps the user wind down'));
      expect(text, isNot(contains('anxiety')));
      expect(text, isNot(contains('medication')));
      expect(p['private_health_notes'], contains('1 private health note'));
    });
  });

  test('a confirmed fact is in the prompt; once deleted it is gone', () {
    String prompt(List<Fact> f) => CompanionAI.chatPrompt(
          userText: 'stressed again',
          context: {'remembered': factsForPrompt(f, PromptScrubber())},
          history: const [],
        ).$1;
    final walk = fact('b', 'A short walk helps when stressed');
    expect(prompt([walk]), contains('A short walk helps when stressed'));
    expect(prompt([]), isNot(contains('short walk')));
    expect(prompt([]), contains('"reply"')); // the JSON answer format is asked for
  });

  test('reply() returns the parsed text and suggestions from the AI', () async {
    final ai = CompanionAI(
      proxyUrl: 'https://proxy.example',
      client: MockClient((_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'reply': 'Noted, walks it is!',
                    'notes': [],
                    'facts': [
                      {'text': 'Walks help', 'category': 'what_helps', 'private': false}
                    ],
                  })
                }
              }
            ]
          }),
          200)),
    )..installId = '3f2b8c1e-9a4d-4e6f-8b2a-1c3d5e7f9a0b';
    final r = await ai.reply(
        userText: 'walks always help me',
        features: BehaviourFeatures.fromLogs([]),
        risk: RiskResult(RiskLevel.low, 0, [], 'h'),
        history: const []);
    expect(r.text, 'Noted, walks it is!');
    expect(r.facts.single.text, 'Walks help');
  });

  test('offline template replies carry no suggestions', () async {
    final r = await CompanionAI(proxyUrl: '').reply(
        userText: 'walks always help me',
        features: BehaviourFeatures.fromLogs([]),
        risk: RiskResult(RiskLevel.low, 0, [], 'h'),
        history: const []);
    expect(r.facts, isEmpty);
    expect(r.text, isNotEmpty);
  });

  test('facts round-trip through JSON', () {
    final f = fact('p', 'Cramps make me scroll more', c: FactCategory.trigger, private: true);
    final back = Fact.fromJson(f.toJson());
    expect(back.toJson(), f.toJson());
    expect(f.toJson()['category'], 'trigger');
    expect(f.toJson()['created_at'], matches(RegExp(r'[+-]\d\d:\d\d$')));
  });
}

