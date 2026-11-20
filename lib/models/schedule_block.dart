import 'package:flutter/material.dart';

/// Kinds of schedule block (C1, FR15–FR17, thesis 3.5.6). A folder groups
/// other blocks (e.g. "On campus"); time inside it with no child block is
/// free time ("on campus, free").
enum BlockType {
  classBlock('class', 'Class', Icons.school_outlined),
  study('study', 'Study', Icons.menu_book_outlined),
  work('work', 'Work', Icons.work_outline),
  sleep('sleep', 'Sleep', Icons.bedtime_outlined),
  breakBlock('break', 'Break', Icons.coffee_outlined),
  personal('personal', 'Personal', Icons.person_outline),
  folder('folder', 'Folder', Icons.folder_outlined);

  const BlockType(this.id, this.label, this.icon);

  /// Value stored in JSON and on logs (`class`, `study`, ...).
  final String id;
  final String label;
  final IconData icon;

  static BlockType fromId(String? id) =>
      values.firstWhere((t) => t.id == id, orElse: () => personal);

  /// Types that count towards how busy a day is.
  bool get isLoad => this == classBlock || this == study || this == work;
}

/// "HH:mm" <-> minutes after midnight.
int parseHm(String s) {
  final p = s.split(':');
  return int.parse(p[0]) * 60 + int.parse(p[1]);
}

String formatHm(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// One repeating block, stored in `blocks` in second_brain.json:
/// {id, title, type, start "HH:mm", end, weekdays [1-7], parent_id?, quiet,
/// cancelled_dates[]}. An end before the start means it runs past midnight
/// (e.g. sleep 23:00-07:00); weekdays are the days it starts on (1 = Monday).
class ScheduleBlock {
  ScheduleBlock({
    required this.id,
    required this.title,
    required this.type,
    required this.start,
    required this.end,
    required this.weekdays,
    this.parentId,
    this.quiet = false,
    Set<String>? cancelledDates,
  }) : cancelledDates = cancelledDates ?? {};

  final String id;
  final String title;
  final BlockType type;

  /// Minutes after midnight.
  final int start, end;
  final Set<int> weekdays;

  /// The folder this block sits in, if any.
  final String? parentId;

  /// No nudges during this block (used by D1/D2).
  final bool quiet;

  /// Dates (`yyyy-MM-dd`) this block is skipped, e.g. "No class today".
  final Set<String> cancelledDates;

  bool get crossesMidnight => end <= start;

  /// Length in minutes, including past midnight.
  int get minutes => crossesMidnight ? end + 24 * 60 - start : end - start;

  ScheduleBlock copyWith({
    String? title,
    BlockType? type,
    int? start,
    int? end,
    Set<int>? weekdays,
    String? parentId,
    bool clearParent = false,
    bool? quiet,
    Set<String>? cancelledDates,
  }) =>
      ScheduleBlock(
        id: id,
        title: title ?? this.title,
        type: type ?? this.type,
        start: start ?? this.start,
        end: end ?? this.end,
        weekdays: weekdays ?? this.weekdays,
        parentId: clearParent ? null : parentId ?? this.parentId,
        quiet: quiet ?? this.quiet,
        cancelledDates: cancelledDates ?? this.cancelledDates,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.id,
        'start': formatHm(start),
        'end': formatHm(end),
        'weekdays': weekdays.toList()..sort(),
        if (parentId != null) 'parent_id': parentId,
        'quiet': quiet,
        'cancelled_dates': cancelledDates.toList()..sort(),
      };

  factory ScheduleBlock.fromJson(Map<String, dynamic> j) => ScheduleBlock(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        type: BlockType.fromId(j['type'] as String?),
        start: parseHm(j['start'] as String),
        end: parseHm(j['end'] as String),
        weekdays: ((j['weekdays'] as List?) ?? const [1, 2, 3, 4, 5, 6, 7])
            .map((d) => (d as num).toInt())
            .toSet(),
        parentId: j['parent_id'] as String?,
        quiet: j['quiet'] as bool? ?? false,
        cancelledDates: ((j['cancelled_dates'] as List?) ?? const []).cast<String>().toSet(),
      );
}
