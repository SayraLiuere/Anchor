import '../models/log_entry.dart';
import '../models/nudge_event.dart';
import '../models/schedule_block.dart';
import 'risk_grid.dart' show psuGroups;
import 'schedule_service.dart';
import 'usage_snapshots.dart';

/// Calendar-aware nudge (D2, thesis 3.5.11).

/// Block types where phone use is nudged. Folders (free time) never are.
const focusTypes = {BlockType.classBlock, BlockType.study, BlockType.work};

/// Minutes at the start and end of a block that are left alone.
const focusEdgeMinutes = 10;

/// Continuous minutes on a social, video or game app before a nudge.
const focusUseMinutes = 10;

class FocusRange {
  FocusRange(this.blockId, this.type, this.start, this.end);

  final String blockId;
  final BlockType type;
  final DateTime start, end;
}

/// Class, study and work blocks from yesterday to [days] days ahead
/// (cancelled dates already skipped), for the worker.
List<FocusRange> focusRanges(ScheduleService s, DateTime now, {int days = 7}) {
  final today = dayOf(now);
  return [
    for (var d = -1; d <= days; d++)
      for (final o in s.occurrencesOn(DateTime(today.year, today.month, today.day + d)))
        if (focusTypes.contains(o.block.type)) FocusRange(o.block.id, o.block.type, o.start, o.end),
  ];
}

Map<String, dynamic> focusPlanJson(List<FocusRange> ranges) => {
      'ranges': [
        for (final r in ranges)
          {
            'block_id': r.blockId,
            'type': r.type.id,
            'start': r.start.millisecondsSinceEpoch,
            'end': r.end.millisecondsSinceEpoch,
          },
      ],
    };

/// The rule the worker applies: inside a class, study or work block but not
/// in its first or last 10 minutes, after 10+ minutes of continuous use of
/// a social, video or game app (counted from the later of the session's and
/// the block's start). Messaging and music never count. Returns the block.
FocusRange? calendarNudgeDue({
  required DateTime now,
  required List<FocusRange> ranges,
  required String group,
  required DateTime sessionStart,
}) {
  if (!psuGroups.contains(group)) return null;
  for (final r in ranges) {
    final inner = !now.isBefore(r.start.add(const Duration(minutes: focusEdgeMinutes))) &&
        !now.isAfter(r.end.subtract(const Duration(minutes: focusEdgeMinutes)));
    if (!inner) continue;
    final from = sessionStart.isAfter(r.start) ? sessionStart : r.start;
    if (now.difference(from).inMinutes >= focusUseMinutes) return r;
  }
  return null;
}

/// Result of merging answers given from the lock screen.
class PendingMerge {
  PendingMerge(this.logs, this.nudges, this.blocks);

  final List<LogEntry> logs;
  final List<NudgeEvent> nudges;
  final List<ScheduleBlock> blocks;
}

DateTime _ms(Object? v) => DateTime.fromMillisecondsSinceEpoch((v as num).toInt());

/// Applies the queue the notification buttons wrote while the app was
/// closed (D2): nudges shown, answers, "No class today" skips, episodes
/// saved by "I'm in class", and the 5-minute check. Unknown kinds are
/// ignored; entries for unknown ids are skipped. Nothing is overwritten.
PendingMerge applyPending(
  List<Map<String, dynamic>> queue, {
  required List<LogEntry> logs,
  required List<NudgeEvent> nudges,
  required List<ScheduleBlock> blocks,
}) {
  final outLogs = [...logs];
  final outNudges = [...nudges];
  final outBlocks = [...blocks];
  int nudgeIndex(Object? id) => outNudges.indexWhere((n) => n.id == id);

  for (final e in queue) {
    switch (e['kind']) {
      case 'nudge':
        if (nudgeIndex(e['id']) >= 0) break;
        outNudges.add(NudgeEvent(
          id: e['id'] as String,
          firedAt: _ms(e['fired_at']),
          type: e['type'] as String? ?? 'calendar',
          group: e['group'] as String?,
          blockType: e['block_type'] as String?,
        ));
      case 'response':
        final i = nudgeIndex(e['nudge_id']);
        if (i >= 0) {
          outNudges[i] = outNudges[i].copyWith(response: e['response'] as String?, respondedAt: _ms(e['at']));
        }
      case 'left_check':
        final i = nudgeIndex(e['nudge_id']);
        if (i >= 0) outNudges[i] = outNudges[i].copyWith(leftWithin5min: e['left'] as bool?);
      case 'cancel_block':
        final i = outBlocks.indexWhere((b) => b.id == e['block_id']);
        if (i >= 0) {
          outBlocks[i] = outBlocks[i].copyWith(
              cancelledDates: {...outBlocks[i].cancelledDates, e['date'] as String});
        }
      case 'episode':
        if (outLogs.any((l) => l.id == e['id'])) break;
        outLogs.add(LogEntry(
          id: e['id'] as String,
          timestamp: _ms(e['at']),
          kind: EntryKind.episode,
          // Not asked from the lock screen: neutral mood and stress, a high
          // urge (they kept scrolling in class). source "nudge" marks these
          // so they stay out of the self-reported averages.
          mood: 3,
          stress: 3,
          craving: 4,
          durationMinutes: (e['minutes'] as num?)?.toInt() ?? 10,
          appGroup: e['group'] as String?,
          blockId: e['block_id'] as String?,
          blockType: e['block_type'] as String?,
          source: 'nudge',
          nudgeId: e['nudge_id'] as String?,
        ));
    }
  }
  return PendingMerge(outLogs, outNudges, outBlocks);
}
