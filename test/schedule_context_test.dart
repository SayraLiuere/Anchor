import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/schedule_block.dart';
import 'package:psu_second_brain/services/chat_context.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/risk_model.dart';
import 'package:psu_second_brain/services/schedule_service.dart';

void main() {
  final blocks = [
    ScheduleBlock(id: 'f', title: 'Campus with Aisyah', type: BlockType.folder,
        start: parseHm('08:00'), end: parseHm('17:00'), weekdays: {1, 2, 3, 4, 5}),
    ScheduleBlock(id: 'c', title: 'SKR3307 Data Mining', type: BlockType.classBlock,
        start: parseHm('09:00'), end: parseHm('11:00'), weekdays: {1, 2, 3, 4, 5}, parentId: 'f'),
  ];

  Map<String, dynamic> ctx(DateTime now) => buildChatContext(
      now: now,
      features: BehaviourFeatures.fromLogs([], now: now),
      risk: RiskResult(RiskLevel.low, 0, [], 'h'),
      logs: const [],
      schedule: ScheduleService(blocks));

  test('Mira knows the block type right now and today\'s load, never titles', () {
    final c = ctx(DateTime(2026, 11, 16, 10));
    final s = c['schedule_today'] as Map<String, dynamic>;
    expect(s['right_now'], 'class');
    expect(s['day_load'], 'light');
    expect(s['blocks'], [{'type': 'class', 'from': '09:00', 'to': '11:00'}]);
    final text = jsonEncode(c);
    for (final secret in ['Aisyah', 'SKR3307', 'Data Mining', 'Campus']) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });

  test('free time inside a folder and empty days are described', () {
    expect((ctx(DateTime(2026, 11, 16, 12))['schedule_today'] as Map)['right_now'],
        'free time between scheduled blocks');
    expect((ctx(DateTime(2026, 11, 21, 12))['schedule_today'] as Map)['right_now'],
        'nothing scheduled');
  });
}
