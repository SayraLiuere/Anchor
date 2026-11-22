import 'timestamps.dart';

/// A nudge the phone showed, and what the user did with it (D2; D3 adds
/// the one-tap answers and fills the follow-up numbers). Stored as
/// `nudges` and exported in Export v2's nudges[].
class NudgeEvent {
  NudgeEvent({
    required this.id,
    required this.firedAt,
    required this.type,
    this.group,
    this.blockType,
    this.response,
    this.respondedAt,
    this.leftWithin5min,
  });

  final String id;
  final DateTime firedAt;

  /// `calendar` (D2), later `limit`, `heads_up`, ...
  final String type;

  /// App group being used (social, video, games); never the app's name.
  final String? group;
  final String? blockType;

  /// `no_class`, `in_class`, `on_break`, or null when not answered.
  final String? response;
  final DateTime? respondedAt;

  /// After "I'm in class": had the user left the app 5 minutes later?
  final bool? leftWithin5min;

  NudgeEvent copyWith({String? response, DateTime? respondedAt, bool? leftWithin5min}) => NudgeEvent(
        id: id,
        firedAt: firedAt,
        type: type,
        group: group,
        blockType: blockType,
        response: response ?? this.response,
        respondedAt: respondedAt ?? this.respondedAt,
        leftWithin5min: leftWithin5min ?? this.leftWithin5min,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'fired_at': toOffsetIso(firedAt),
        'type': type,
        if (group != null) 'group': group,
        if (blockType != null) 'block_type': blockType,
        'response': response,
        if (respondedAt != null) 'responded_at': toOffsetIso(respondedAt!),
        if (leftWithin5min != null) 'left_within_5min': leftWithin5min,
      };

  factory NudgeEvent.fromJson(Map<String, dynamic> j) => NudgeEvent(
        id: j['id'] as String,
        firedAt: parseTimestamp(j['fired_at'] as String),
        type: j['type'] as String? ?? 'unknown',
        group: j['group'] as String?,
        blockType: j['block_type'] as String?,
        response: j['response'] as String?,
        respondedAt: j['responded_at'] == null ? null : parseTimestamp(j['responded_at'] as String),
        leftWithin5min: j['left_within_5min'] as bool?,
      );
}
