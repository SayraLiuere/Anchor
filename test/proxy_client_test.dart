import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:psu_second_brain/services/companion_ai.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';

const id = '3f2b8c1e-9a4d-4e6f-8b2a-1c3d5e7f9a0b';

void main() {
  final features = BehaviourFeatures.fromLogs([]);
  final risk = RiskResult(RiskLevel.low, 0, [], 'test');

  CompanionAI ai(MockClient client, {String url = 'https://proxy.example'}) =>
      CompanionAI(client: client, proxyUrl: url)..installId = id;

  Future<String> chat(CompanionAI a) =>
      a.reply(userText: 'hey mira', features: features, risk: risk, history: []);

  test('proxy is the default and needs no key', () {
    final a = CompanionAI(proxyUrl: 'https://proxy.example')..installId = id;
    expect(a.provider, LlmProvider.proxy);
    expect(a.apiKey, isEmpty);
    expect(a.online, isTrue);
    expect(LlmProvider.proxy.needsKey, isFalse);
  });

  test('request goes to the proxy with the install ID and no key', () async {
    late http.Request sent;
    final a = ai(MockClient((r) async {
      sent = r;
      return http.Response(
          jsonEncode({'choices': [{'message': {'content': 'hi friend!'}}]}), 200);
    }));
    expect(await chat(a), 'hi friend!');
    expect(sent.url.toString(), 'https://proxy.example/v1/chat/completions');
    expect(sent.headers['X-Install-Id'], id);
    expect(sent.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['model'], 'default');
    expect((body['messages'] as List).first['role'], 'system');
    expect((body['messages'] as List).last['content'], 'hey mira');
  });

  test('the daily limit (429) gives the friendly message, not a template', () async {
    final a = ai(MockClient((_) async => http.Response(
        jsonEncode({'error': {'code': 'daily_limit', 'message': 'Daily limit of 50 messages reached.'}}),
        429)));
    expect(await chat(a), CompanionAI.dailyLimitMessage);
    expect(a.limitReached, isTrue);
    expect(a.lastError, contains('Daily limit'));
  });

  test('other proxy errors fall back to template replies', () async {
    final a = ai(MockClient((_) async =>
        http.Response(jsonEncode({'error': {'message': 'The AI service returned 500'}}), 502)));
    final r = await chat(a);
    expect(r, isNot(CompanionAI.dailyLimitMessage));
    expect(r, isNotEmpty);
    expect(a.lastError, contains('502'));
  });

  test('no proxy URL in the build means offline templates, no network call', () async {
    var called = false;
    final a = ai(MockClient((_) async {
      called = true;
      return http.Response('', 200);
    }), url: '');
    expect(a.online, isFalse);
    expect(await chat(a), isNotEmpty);
    expect(called, isFalse);
  });

  test('saved provider: keyless installs move to the proxy, dev keys stay', () {
    expect(providerAfterLoad(null, hasKey: false), LlmProvider.proxy);
    expect(providerAfterLoad('openai', hasKey: false), LlmProvider.proxy);
    expect(providerAfterLoad('openai', hasKey: true), LlmProvider.openai);
    expect(providerAfterLoad('gemini', hasKey: true), LlmProvider.gemini);
    expect(providerAfterLoad('proxy', hasKey: true), LlmProvider.proxy);
    expect(providerAfterLoad('nonsense', hasKey: true), LlmProvider.proxy);
  });

  test('crisis text never reaches the proxy', () async {
    var called = false;
    final a = ai(MockClient((_) async {
      called = true;
      return http.Response('', 200);
    }));
    final r = await a.reply(
        userText: 'i want to die', features: features, risk: risk, history: []);
    expect(r, CompanionAI.crisisMessage);
    expect(called, isFalse);
  });
}
