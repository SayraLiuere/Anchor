import '../models/schedule_block.dart';
import 'usage_snapshots.dart' show dateKey;

/// One block on one day, with real start and end times.
class BlockOccurrence {
  BlockOccurrence(this.block, this.start, this.end);

  final ScheduleBlock block;
  final DateTime start, end;

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);
  double get hours => end.difference(start).inMinutes / 60;
}

/// A free stretch inside a folder ("on campus, free").
class FreeGap {
  FreeGap(this.folder, this.start, this.end);

  final ScheduleBlock folder;
  final DateTime start, end;
}

enum DayLoad {
  light('Light'),
  normal('Normal'),
  packed('Packed');

  const DayLoad(this.label);
  final String label;
}

/// Today's busyness: hours per block type and an overall label.
class TodayLoad {
  TodayLoad(this.hoursByType, this.label);

  final Map<BlockType, double> hoursByType;
  final DayLoad label;

  /// Class + study + work hours.
  double get busyHours =>
      hoursByType.entries.where((e) => e.key.isLoad).fold(0.0, (a, e) => a + e.value);
}

/// Schedule logic over a list of blocks (C1). Pure: give it the time.
class ScheduleService {
  ScheduleService(this.blocks);

  final List<ScheduleBlock> blocks;

  /// Busy-hour cut-offs for the day label: up to 3 h light, up to 6 h normal.
  static const lightMaxHours = 3.0, normalMaxHours = 6.0;

  /// Blocks that start on [day], skipping cancelled dates; oldest first.
  List<BlockOccurrence> occurrencesOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final key = dateKey(d);
    return [
      for (final b in blocks)
        if (b.weekdays.contains(d.weekday) && !b.cancelledDates.contains(key))
          BlockOccurrence(
            b,
            DateTime(d.year, d.month, d.day, 0, b.start),
            DateTime(d.year, d.month, d.day, 0, b.start + b.minutes),
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  /// What today's list shows: blocks starting on [day], plus blocks from the
  /// day before that run past midnight into it (e.g. last night's sleep).
  List<BlockOccurrence> occurrencesTouching(DateTime day) {
    final midnight = DateTime(day.year, day.month, day.day);
    return [
      ...occurrencesOn(midnight.subtract(const Duration(days: 1)))
          .where((o) => o.end.isAfter(midnight)),
      ...occurrencesOn(midnight),
    ];
  }

  /// Free gaps for today's list, including the after-midnight part of last
  /// night's folders.
  List<FreeGap> gapsTouching(DateTime day) {
    final midnight = DateTime(day.year, day.month, day.day);
    return [
      ...gapsOn(midnight.subtract(const Duration(days: 1))).where((g) => g.end.isAfter(midnight)),
      ...gapsOn(midnight),
    ];
  }

  /// Everything running at [now], including blocks that began yesterday and
  /// run past midnight.
  List<BlockOccurrence> activeAt(DateTime now) => [
        for (final o in [
          ...occurrencesOn(now.subtract(const Duration(days: 1))),
          ...occurrencesOn(now),
        ])
          if (o.contains(now)) o,
      ];

  /// The most specific block at [now]: a regular block (the latest-starting
  /// one if several overlap) beats the folder it sits in. Returns the folder
  /// itself when [now] falls in a gap inside it, and null when nothing is on.
  BlockOccurrence? currentOccurrence(DateTime now) {
    final active = activeAt(now);
    final regular = active.where((o) => o.block.type != BlockType.folder).toList();
    if (regular.isNotEmpty) {
      return regular.reduce((a, b) => b.start.isAfter(a.start) ? b : a);
    }
    return active.isEmpty ? null : active.last;
  }

  ScheduleBlock? currentBlock(DateTime now) => currentOccurrence(now)?.block;

  /// True when [now] is inside a folder but in none of its blocks.
  bool inFolderGap(DateTime now) => currentBlock(now)?.type == BlockType.folder;

  /// Free stretches inside each folder that starts on [day].
  List<FreeGap> gapsOn(DateTime day) {
    final all = occurrencesOn(day);
    // A folder that runs past midnight holds blocks that start the next day.
    final next = occurrencesOn(DateTime(day.year, day.month, day.day + 1));
    final gaps = <FreeGap>[];
    for (final f in all.where((o) => o.block.type == BlockType.folder)) {
      final children = [...all, ...next]
          .where((o) => o.block.parentId == f.block.id && f.contains(o.start))
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      var cursor = f.start;
      for (final c in children) {
        if (c.start.isAfter(cursor)) gaps.add(FreeGap(f.block, cursor, c.start));
        if (c.end.isAfter(cursor)) cursor = c.end;
      }
      if (cursor.isBefore(f.end)) gaps.add(FreeGap(f.block, cursor, f.end));
    }
    return gaps.where((g) => g.end.isAfter(g.start)).toList();
  }

  /// Hours by type for blocks starting on [day] (folders not counted), and
  /// a light / normal / packed label from class, study and work hours.
  TodayLoad todayLoad(DateTime day) {
    final hours = <BlockType, double>{};
    for (final o in occurrencesOn(day)) {
      if (o.block.type == BlockType.folder) continue;
      hours[o.block.type] = (hours[o.block.type] ?? 0) + o.hours;
    }
    final busy = hours.entries.where((e) => e.key.isLoad).fold(0.0, (a, e) => a + e.value);
    final label = busy <= lightMaxHours
        ? DayLoad.light
        : busy <= normalMaxHours
            ? DayLoad.normal
            : DayLoad.packed;
    return TodayLoad(hours, label);
  }

  /// Block id and type to store on a log made at [at]: the current block, or
  /// the folder when it is a free gap inside one. Null when nothing is on.
  (String, String)? tagFor(DateTime at) {
    final b = currentBlock(at);
    return b == null ? null : (b.id, b.type.id);
  }
}
