import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/schedule_block.dart';
import 'package:psu_second_brain/services/schedule_service.dart';

void main() {
  // A late folder that runs past midnight, with a class and a study block.
  final folder = ScheduleBlock(id: 'f', title: 'Late session', type: BlockType.folder,
      start: parseHm('23:30'), end: parseHm('02:00'), weekdays: {1, 2, 3, 4, 5, 6, 7});
  final night = ScheduleBlock(id: 'n', title: 'Night class', type: BlockType.classBlock,
      start: parseHm('23:45'), end: parseHm('00:30'), weekdays: {1, 2, 3, 4, 5, 6, 7}, parentId: 'f');
  final study = ScheduleBlock(id: 's', title: 'Study', type: BlockType.study,
      start: parseHm('01:00'), end: parseHm('01:45'), weekdays: {1, 2, 3, 4, 5, 6, 7}, parentId: 'f');
  final s = ScheduleService([folder, night, study]);
  final sat = DateTime(2026, 11, 21);

  test("today's list includes last night's blocks that run past midnight", () {
    final list = s.occurrencesTouching(sat);
    // Friday 23:30 folder and 23:45 class still running after midnight; the
    // Saturday 01:00 study (it starts on Saturday) and Saturday night's blocks.
    expect(list.map((o) => '${o.block.id}@${o.start.day}'),
        ['f@20', 'n@20', 's@21', 'f@21', 'n@21']);
  });

  test('gaps in a folder that runs past midnight go around blocks after midnight', () {
    String fmt(FreeGap g) => '${g.start.day} ${g.start.hour}:${g.start.minute.toString().padLeft(2, '0')}'
        '-${g.end.hour}:${g.end.minute.toString().padLeft(2, '0')}';
    // Friday night's folder: free 23:30-23:45, class, free 00:30-01:00, study,
    // free 01:45-02:00. Only the parts after Saturday midnight are listed.
    expect(s.gapsOn(DateTime(2026, 11, 20)).map(fmt),
        ['20 23:30-23:45', '21 0:30-1:00', '21 1:45-2:00']);
    expect(s.gapsTouching(sat).map(fmt).take(2), ['21 0:30-1:00', '21 1:45-2:00']);
  });

  test('just after midnight the class from last night is the current block', () {
    final now = DateTime(2026, 11, 21, 0, 10);
    final o = s.currentOccurrence(now)!;
    expect(o.block.id, 'n');
    expect(o.start, DateTime(2026, 11, 20, 23, 45));
    expect(s.tagFor(now), ('n', 'class'));
    expect(s.tagFor(DateTime(2026, 11, 21, 0, 45)), ('f', 'folder'));
  });
}
