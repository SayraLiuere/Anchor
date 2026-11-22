import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/models/nudge_event.dart';
import 'package:psu_second_brain/models/schedule_block.dart';
import 'package:psu_second_brain/services/features.dart';
import 'package:psu_second_brain/services/focus.dart';
import 'package:psu_second_brain/services/schedule_service.dart';

DateTime mon(int h, [int m = 0]) => DateTime(2026, 11, 23, h, m);

final campus = ScheduleBlock(id: 'campus', title: 'Campus', type: BlockType.folder,
    start: parseHm('08:00'), end: parseHm('17:00'), weekdays: {1});
final lecture = ScheduleBlock(id: 'lec', title: 'Lecture', type: BlockType.classBlock,
    start: parseHm('09:00'), end: parseHm('11:00'), weekdays: {1}, parentId: 'campus');
final gym = ScheduleBlock(id: 'gym', title: 'Gym', type: BlockType.personal,
    start: parseHm('18:00'), end: parseHm('19:00'), weekdays: {1});
final shift = ScheduleBlock(id: 'shift', title: 'Shift', type: BlockType.work,
    start: parseHm('22:00'), end: parseHm('02:00'), weekdays: {1});

List<FocusRange> ranges([List<ScheduleBlock>? extra]) =>
    focusRanges(ScheduleService([campus, lecture, gym, shift, ...?extra]), mon(0));

void main() {
  test('only class, study and work blocks become focus ranges', () {
    final r = ranges();
    expect(r.map((x) => x.blockId).toSet(), {'lec', 'shift'});
    final s = r.firstWhere((x) => x.blockId == 'shift');
    expect(s.end, DateTime(2026, 11, 24, 2)); // runs past midnight
    final plan = focusPlanJson(r);
    expect((plan['ranges'] as List).first['type'], 'class');
  });

  test('nudge after 10+ min of social, video or games inside a class', () {
    final r = ranges();
    expect(calendarNudgeDue(now: mon(9, 30), ranges: r, group: 'video', sessionStart: mon(9, 15))?.blockId,
        'lec');
    expect(calendarNudgeDue(now: mon(9, 30), ranges: r, group: 'video', sessionStart: mon(9, 25)), isNull);
  });

  test('never in the first or last 10 minutes, in free time or other blocks', () {
    final r = ranges();
    expect(calendarNudgeDue(now: mon(9, 8), ranges: r, group: 'social', sessionStart: mon(8, 30)), isNull);
    expect(calendarNudgeDue(now: mon(10, 55), ranges: r, group: 'social', sessionStart: mon(10, 0)), isNull);
    expect(calendarNudgeDue(now: mon(12), ranges: r, group: 'social', sessionStart: mon(11, 30)), isNull);
    expect(calendarNudgeDue(now: mon(18, 30), ranges: r, group: 'games', sessionStart: mon(18)), isNull);
  });

  test('use before the block only counts from the block start', () {
    final r = ranges();
    // Scrolling since 08:30; at 09:12 that is 12 min inside class.
    expect(calendarNudgeDue(now: mon(9, 12), ranges: r, group: 'social', sessionStart: mon(8, 30)), isNotNull);
  });

  test('messaging and music never trigger it', () {
    final r = ranges();
    for (final g in ['chat', 'audio', 'other']) {
      expect(calendarNudgeDue(now: mon(9, 40), ranges: r, group: g, sessionStart: mon(9)), isNull, reason: g);
    }
  });

  test('a cancelled class is no focus range', () {
    final only = focusRanges(
        ScheduleService([lecture.copyWith(cancelledDates: {'2026-11-23'})]), mon(0));
    // Today's class is skipped; next Monday's still counts.
    expect(only.map((x) => x.start), [DateTime(2026, 11, 30, 9)]);
  });

  group('merging answers from the lock screen', () {
    final at = mon(9, 30).millisecondsSinceEpoch;
    final queue = <Map<String, dynamic>>[
      {'kind': 'nudge', 'id': 'n1', 'fired_at': at, 'type': 'calendar', 'group': 'video', 'block_type': 'class'},
      {'kind': 'response', 'nudge_id': 'n1', 'response': 'in_class', 'at': at + 60000},
      {'kind': 'episode', 'id': 'e1', 'at': at + 60000, 'group': 'video', 'minutes': 15,
        'block_id': 'lec', 'block_type': 'class', 'nudge_id': 'n1'},
      {'kind': 'left_check', 'nudge_id': 'n1', 'left': true},
      {'kind': 'cancel_block', 'block_id': 'lec', 'date': '2026-11-30'},
      {'kind': 'response', 'nudge_id': 'unknown', 'response': 'on_break', 'at': at},
      {'kind': 'something_new'},
    ];

    test('nudge, answer, episode, 5-minute check and skipped class', () {
      final m = applyPending(queue, logs: const [], nudges: const [], blocks: [lecture]);
      final n = m.nudges.single;
      expect((n.response, n.leftWithin5min, n.group, n.blockType), ('in_class', true, 'video', 'class'));
      final e = m.logs.single;
      expect((e.source, e.nudgeId, e.blockType, e.appGroup, e.durationMinutes), ('nudge', 'n1', 'class', 'video', 15));
      expect(e.appLabel, isNull); // no app name from the lock screen
      expect(m.blocks.single.cancelledDates, {'2026-11-30'});
    });

    test('applying the same queue twice changes nothing more', () {
      final once = applyPending(queue, logs: const [], nudges: const [], blocks: [lecture]);
      final twice = applyPending(queue, logs: once.logs, nudges: once.nudges, blocks: once.blocks);
      expect(twice.logs, hasLength(1));
      expect(twice.nudges, hasLength(1));
    });

    test('nudge episodes count as episodes but not in mood, stress or urge', () {
      final now = mon(12);
      final m = applyPending(queue, logs: [
        LogEntry(id: 'own', timestamp: mon(8), kind: EntryKind.checkIn, mood: 1, stress: 5, craving: 2),
      ], nudges: const [], blocks: const []);
      final f = BehaviourFeatures.fromLogs(m.logs, now: now);
      expect(f.episodeCount, 1);
      expect((f.meanMood, f.meanStress, f.meanCraving), (1, 5, 2));
    });

    test('nudge events round-trip through JSON', () {
      final n = applyPending(queue, logs: const [], nudges: const [], blocks: const []).nudges.single;
      final back = NudgeEvent.fromJson(n.toJson());
      expect(back.toJson(), n.toJson());
      expect(n.toJson()['fired_at'], matches(RegExp(r'[+-]\d\d:\d\d$')));
    });
  });
}
