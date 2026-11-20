import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/log_entry.dart';
import 'package:psu_second_brain/models/schedule_block.dart';
import 'package:psu_second_brain/services/schedule_service.dart';

// Mon 16 Nov 2026 ... Sun 22 Nov 2026.
DateTime mon(int h, [int m = 0]) => DateTime(2026, 11, 16, h, m);
DateTime tue(int h, [int m = 0]) => DateTime(2026, 11, 17, h, m);
DateTime wed(int h, [int m = 0]) => DateTime(2026, 11, 18, h, m);
DateTime sat(int h, [int m = 0]) => DateTime(2026, 11, 21, h, m);

const weekdays = {1, 2, 3, 4, 5};

final campus = ScheduleBlock(
    id: 'campus', title: 'On campus', type: BlockType.folder,
    start: parseHm('08:00'), end: parseHm('17:00'), weekdays: weekdays);
final lecture = ScheduleBlock(
    id: 'lec', title: 'Lecture', type: BlockType.classBlock,
    start: parseHm('09:00'), end: parseHm('11:00'), weekdays: weekdays, parentId: 'campus');
final lab = ScheduleBlock(
    id: 'lab', title: 'Lab', type: BlockType.classBlock,
    start: parseHm('14:00'), end: parseHm('16:00'), weekdays: weekdays, parentId: 'campus',
    quiet: true);
final sleep = ScheduleBlock(
    id: 'sleep', title: 'Sleep', type: BlockType.sleep,
    start: parseHm('23:00'), end: parseHm('07:00'), weekdays: {1});

ScheduleService service([List<ScheduleBlock>? extra]) =>
    ScheduleService([campus, lecture, lab, sleep, ...?extra]);

void main() {
  test('nested blocks: a class inside a folder wins over the folder', () {
    final s = service();
    expect(s.currentBlock(mon(10))!.id, 'lec');
    expect(s.currentBlock(mon(15, 30))!.id, 'lab');
    expect(s.currentBlock(mon(11))!.id, 'campus'); // end is exclusive
    expect(s.currentBlock(mon(18)), isNull);
    expect(s.currentBlock(sat(10)), isNull); // weekdays only
  });

  test('gaps inside a folder are free time ("on campus, free")', () {
    final s = service();
    expect(s.inFolderGap(mon(12)), isTrue);
    expect(s.inFolderGap(mon(10)), isFalse);
    final gaps = s.gapsOn(mon(0)).map((g) => '${g.start.hour}-${g.end.hour}').toList();
    expect(gaps, ['8-9', '11-14', '16-17']);
  });

  test('blocks that run past midnight count on the next morning', () {
    final s = service();
    expect(s.currentBlock(mon(23, 30))!.id, 'sleep');
    expect(s.currentBlock(tue(2))!.id, 'sleep'); // started Monday night
    expect(s.currentBlock(tue(7)), isNull);
    expect(s.currentBlock(wed(2)), isNull); // no sleep block starts on Tuesday
    expect(sleep.minutes, 8 * 60);
    expect(sleep.crossesMidnight, isTrue);
  });

  test('a cancelled date skips the block; the folder time is free instead', () {
    final s = ScheduleService(
        [campus, lecture.copyWith(cancelledDates: {'2026-11-16'}), lab]);
    expect(s.currentBlock(mon(10))!.id, 'campus');
    expect(s.currentBlock(tue(10))!.id, 'lec');
    expect(s.gapsOn(mon(0)).map((g) => '${g.start.hour}-${g.end.hour}'), ['8-14', '16-17']);
  });

  test('overlapping regular blocks: the one that started last wins', () {
    final study = ScheduleBlock(
        id: 'study', title: 'Group study', type: BlockType.study,
        start: parseHm('10:00'), end: parseHm('12:00'), weekdays: weekdays);
    final s = service([study]);
    expect(s.currentBlock(mon(10, 30))!.id, 'study');
    expect(s.currentBlock(mon(9, 30))!.id, 'lec');
  });

  test('today load: hours by type and a light / normal / packed label', () {
    final load = service().todayLoad(mon(0));
    expect(load.hoursByType[BlockType.classBlock], 4);
    expect(load.hoursByType[BlockType.sleep], 8);
    expect(load.hoursByType.containsKey(BlockType.folder), isFalse);
    expect(load.busyHours, 4);
    expect(load.label, DayLoad.normal);
    expect(service().todayLoad(sat(0)).label, DayLoad.light);
    final long = ScheduleBlock(
        id: 'w', title: 'Shift', type: BlockType.work,
        start: parseHm('17:00'), end: parseHm('21:00'), weekdays: {1});
    expect(service([long]).todayLoad(mon(0)).label, DayLoad.packed);
  });

  test('a log made during class is labelled class', () {
    final at = mon(9, 45);
    final (id, type) = service().tagFor(at)!;
    final log = LogEntry(
        id: 'x', timestamp: at, kind: EntryKind.episode, mood: 3, stress: 3, craving: 3,
        blockId: id, blockType: type);
    expect(log.blockType, 'class');
    final back = LogEntry.fromJson(log.toJson());
    expect((back.blockId, back.blockType), ('lec', 'class'));
    expect(service().tagFor(mon(12)), ('campus', 'folder'));
    expect(service().tagFor(sat(12)), isNull);
  });

  test('blocks round-trip through JSON, and old logs load without a block', () {
    final back = ScheduleBlock.fromJson(lab.toJson());
    expect(back.toJson(), lab.toJson());
    expect(lab.toJson()['start'], '14:00');
    expect(lab.toJson()['type'], 'class');
    expect(back.quiet, isTrue);
    expect(back.parentId, 'campus');
    final old = LogEntry.fromJson({
      'id': 'o', 'timestamp': '2026-11-10T10:00:00', 'kind': 'episode',
      'mood_rating': 3, 'perceived_stress': 3, 'craving_intensity': 3,
      'trigger_category': [],
    });
    expect(old.blockId, isNull);
    expect(old.toJson().containsKey('block_type'), isFalse);
  });
}

