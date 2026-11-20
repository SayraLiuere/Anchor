import 'package:flutter_test/flutter_test.dart';
import 'package:psu_second_brain/models/context_note.dart';

ContextNote gentle(String date, DateTime? until) => ContextNote(
    id: date, date: date, type: NoteType.plan, label: 'Gentle evening', until: until);

void main() {
  test("last night's gentle evening still pauses warnings after midnight", () {
    final set21 = gentle('2026-11-20', gentleEveningEnds(DateTime(2026, 11, 20, 21)));
    expect(warningsPausedUntil([set21], DateTime(2026, 11, 21, 1)), DateTime(2026, 11, 21, 6));
    expect(warningsPausedUntil([set21], DateTime(2026, 11, 21, 6, 1)), isNull);
  });

  test('other notes, deleted plans and older notes without an end', () {
    final mood = ContextNote(id: 'm', date: '2026-11-21', type: NoteType.mood, label: 'Gentle evening vibes');
    expect(warningsPausedUntil([mood], DateTime(2026, 11, 21, 20)), isNull);
    expect(warningsPausedUntil([], DateTime(2026, 11, 21, 20)), isNull);
    final noEnd = gentle('2026-11-21', null);
    expect(warningsPausedUntil([noEnd], DateTime(2026, 11, 21, 22)), DateTime(2026, 11, 22, 6));
  });

  test('the end time round-trips with its offset', () {
    final n = gentle('2026-11-21', DateTime(2026, 11, 22, 6));
    expect(n.toJson()['until'], matches(RegExp(r'^2026-11-22T06:00:00[+-]\d\d:\d\d$')));
    expect(ContextNote.fromJson(n.toJson()).until, DateTime(2026, 11, 22, 6));
  });
}
