import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/services/companion_ai.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';

void main() {
  test('chat asks for JSON mode; the weekly recap does not', () async {
    final bodies = <Map<String, dynamic>>[];
    final ai = CompanionAI(
      proxyUrl: 'https://proxy.example',
      client: MockClient((r) async {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response(
            jsonEncode({'choices': [{'message': {'content': '{"reply": "hi", "facts": []}'}}]}), 200);
      }),
    )..installId = '3f2b8c1e-9a4d-4e6f-8b2a-1c3d5e7f9a0b';
    final now = DateTime.now();
    final f = BehaviourFeatures.fromLogs([
      LogEntry(id: 'a', timestamp: now, kind: EntryKind.episode, mood: 3, stress: 3, craving: 3),
    ], now: now);
    final risk = RiskResult(RiskLevel.low, 0, ['x'], 'h');

    await ai.reply(userText: 'hey', features: f, risk: risk, history: const []);
    expect(bodies.last['response_format'], {'type': 'json_object'});

    await ai.weeklySummary(f, risk, context: const {'x': 1});
    expect(bodies, hasLength(2));
    expect(bodies.last.containsKey('response_format'), isFalse);
  });
}
