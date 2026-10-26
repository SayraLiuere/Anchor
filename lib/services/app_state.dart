import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/log_entry.dart';
import 'companion_ai.dart';
import 'features.dart';
import 'risk_model.dart';
import 'screen_time.dart';

/// Mira's pet mood, shown on her face and in her lines.
enum PetMood { happy, calm, excited, worried, sleepy }

/// Data layer + glue between the four architecture layers (thesis 4.3).
/// Everything is kept on-device in a single JSON file.
class AppState extends ChangeNotifier {
  final _uuid = const Uuid();
  final ai = CompanionAI();
  final screen = ScreenTimeService();

  RiskModel riskModel = HeuristicRiskModel();
  List<LogEntry> logs = [];
  List<ChatMessage> chat = [];
  String displayName = '';
  String? weeklySummary;
  DateTime? weeklySummaryAt;
  bool onboarded = false;
  bool loading = true;
  bool companionTyping = false;

  // Screen time (opt-in) and notifications
  bool usageGranted = false;
  bool notificationsGranted = false;
  UsageSummary? todayUsage;
  List<UsageSummary> weekUsage = [];
  NudgeSettings nudges = NudgeSettings();

  /// Set when a notification was tapped ("log" or "checkin"); the UI consumes it.
  String? pendingAction;

  late BehaviourFeatures features;
  late RiskResult risk;

  File? _file;

  Future<void> init() async {
    riskModel = await RiskModel.load();
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/second_brain.json');
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        logs = (j['logs'] as List)
            .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        chat = (j['chat'] as List? ?? [])
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        displayName = j['displayName'] as String? ?? '';
        ai.provider = LlmProvider.values.asNameMap()[j['provider']] ?? LlmProvider.openai;
        ai.apiKey = j['apiKey'] as String? ?? '';
        ai.model = j['model'] as String? ?? ai.provider.defaultModel;
        weeklySummary = j['weeklySummary'] as String?;
        final at = j['weeklySummaryAt'] as String?;
        weeklySummaryAt = at == null ? null : DateTime.parse(at);
        onboarded = j['onboarded'] as bool? ?? false;
        if (j['nudges'] != null) {
          nudges = NudgeSettings.fromJson(j['nudges'] as Map<String, dynamic>);
        }
        if (j['dismissedDrafts'] != null) {
          dismissedDrafts = (j['dismissedDrafts'] as List).cast<String>().toSet();
        }
      }
    } catch (e) {
      debugPrint('Failed to load data: $e');
    }
    screen.onLaunchAction = (a) {
      pendingAction = a;
      notifyListeners();
    };
    pendingAction = await screen.takeLaunchAction();
    _recompute();
    loading = false;
    notifyListeners();
    await screen.pushSettings(nudges);
    await refreshDevice();
  }

  /// Re-reads permissions and screen time. Called on start and app resume.
  Future<void> refreshDevice() async {
    usageGranted = await screen.hasUsagePermission();
    notificationsGranted = await screen.hasNotificationPermission();
    if (usageGranted) {
      try {
        todayUsage = await screen.today();
        weekUsage = await screen.daily(days: 7);
        await _refreshDrafts();
      } catch (e) {
        debugPrint('Usage read failed: $e');
      }
    } else {
      todayUsage = null;
      weekUsage = [];
      await _refreshDrafts();
    }
    _recompute();
    notifyListeners();
  }

  void _recompute() {
    logs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    features = BehaviourFeatures.fromLogs(logs,
        screen: usageGranted ? ScreenTimeFeatures.fromDaily(weekUsage) : null);
    risk = riskModel.predict(features);
  }

  Future<void> _saving = Future.value();

  /// Saves are queued so two writes never interleave, and each one goes to a
  /// temp file that atomically replaces the real file (no torn JSON).
  Future<void> _save() => _saving = _saving.then((_) => _write()).catchError(
      (Object e) => debugPrint('Save failed: $e'));

  Future<void> _write() async {
    if (_file == null) return;
    final tmp = File('${_file!.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'logs': logs.map((e) => e.toJson()).toList(),
      'chat': chat.map((e) => e.toJson()).toList(),
      'displayName': displayName,
      'provider': ai.provider.name,
      'apiKey': ai.apiKey,
      'model': ai.model,
      'weeklySummary': weeklySummary,
      'weeklySummaryAt': weeklySummaryAt?.toIso8601String(),
      'onboarded': onboarded,
      'nudges': nudges.toJson(),
      'dismissedDrafts': dismissedDrafts.toList(),
    }), flush: true);
    await tmp.rename(_file!.path);
  }

  void _changed() {
    _recompute();
    notifyListeners();
    _save();
  }

  String? takePendingAction() {
    final a = pendingAction;
    pendingAction = null;
    return a;
  }

  // ---------- Pet ----------

  PetMood get petMood {
    final h = DateTime.now().hour;
    final lastChat = chat.isEmpty ? null : chat.last.at;
    if (lastChat != null && DateTime.now().difference(lastChat).inMinutes < 3) {
      return PetMood.excited;
    }
    if (h >= 23 || h < 5) return PetMood.sleepy;
    return switch (risk.level) {
      RiskLevel.high => PetMood.worried,
      RiskLevel.medium => PetMood.calm,
      RiskLevel.low => PetMood.happy,
    };
  }

  /// Days in the last 30 with at least one log or chat: Mira's "bond" with you.
  int get bondDays {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final days = <String>{
      for (final l in logs)
        if (l.timestamp.isAfter(cutoff) && !l.synthetic)
          '${l.timestamp.year}-${l.timestamp.month}-${l.timestamp.day}',
      for (final m in chat)
        if (m.fromUser && m.at.isAfter(cutoff)) '${m.at.year}-${m.at.month}-${m.at.day}',
    };
    return days.length;
  }

  // ---------- Logging ----------

  LogEntry addLog({
    required EntryKind kind,
    required int mood,
    required int stress,
    required int craving,
    List<Trigger> triggers = const [],
    int durationMinutes = 0,
    bool resisted = false,
    String note = '',
    DateTime? at,
    DetectedSession? draft,
  }) {
    final entry = LogEntry(
      id: _uuid.v4(),
      timestamp: at ?? DateTime.now(),
      kind: kind,
      mood: mood,
      stress: stress,
      craving: craving,
      triggers: triggers,
      durationMinutes: durationMinutes,
      resisted: resisted,
      note: note,
      appPackage: draft?.package,
      appLabel: draft?.label,
      draftId: draft?.id,
    );
    logs.add(entry);
    screen.markLogged(DateTime.now());
    _updateDrafts();
    _changed();
    return entry;
  }

  void deleteLog(String id) {
    logs.removeWhere((l) => l.id == id);
    _updateDrafts();
    _changed();
  }

  // ---------- Auto-drafted episodes ----------

  /// Long sessions from the last 48 h, before filtering.
  List<DetectedSession> _sessions = [];

  /// Sessions waiting for the user to say why (or skip). Newest first.
  List<DetectedSession> drafts = [];

  /// Draft ids the user chose to skip ("not a problem").
  Set<String> dismissedDrafts = {};

  void _updateDrafts() {
    drafts = pendingDrafts(
      _sessions,
      dismissed: dismissedDrafts,
      logged: {for (final l in logs) if (l.draftId != null) l.draftId!},
    );
  }

  Future<void> _refreshDrafts() async {
    if (!usageGranted) {
      _sessions = [];
    } else {
      final now = DateTime.now();
      _sessions = await screen.episodes(
          now.subtract(const Duration(hours: 48)), now,
          minMinutes: nudges.draftMinutes);
    }
    _updateDrafts();
  }

  DetectedSession? draftById(String id) =>
      drafts.where((d) => d.id == id).firstOrNull;

  void dismissDraft(String id) {
    dismissedDrafts.add(id);
    // Keep the set small: skipped sessions older than 3 days can't come back.
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    dismissedDrafts.removeWhere(
        (d) => DetectedSession.startOf(d)?.isBefore(cutoff) ?? true);
    _updateDrafts();
    _changed();
  }

  // ---------- Companion ----------

  Future<void> sendToCompanion(String text) async {
    chat.add(ChatMessage(fromUser: true, text: text));
    companionTyping = true;
    notifyListeners();
    final answer = await ai.reply(
      userText: text,
      features: features,
      risk: risk,
      history: chat.sublist(0, chat.length - 1),
    );
    chat.add(ChatMessage(fromUser: false, text: answer));
    companionTyping = false;
    notifyListeners();
    _save();
  }

  /// Short companion acknowledgement after a log is saved (thesis 4.7).
  Future<void> reactToLog(LogEntry e) async {
    final desc = StringBuffer(e.kind != EntryKind.episode
        ? 'Quick check-in'
        : e.appLabel != null
            ? 'You noticed I spent ${e.durationMinutes} min on ${e.appLabel}'
            : 'I just logged a phone episode');
    if (e.triggers.isNotEmpty) {
      desc.write(' (${e.triggers.map((t) => t.label.toLowerCase()).join(', ')})');
    }
    if (e.kind == EntryKind.episode) {
      desc.write(e.resisted ? ' and I managed to resist.' : ', about ${e.durationMinutes} min.');
    }
    desc.write(' Mood ${e.mood}/5, stress ${e.stress}/5, urge ${e.craving}/5.');
    if (e.note.isNotEmpty) desc.write(' Note: ${e.note}');
    await sendToCompanion(desc.toString());
  }

  void clearChat() {
    chat.clear();
    _changed();
  }

  Future<void> generateWeeklySummary() async {
    companionTyping = true;
    notifyListeners();
    weeklySummary = await ai.weeklySummary(features, risk);
    weeklySummaryAt = DateTime.now();
    companionTyping = false;
    _changed();
  }

  // ---------- Settings ----------

  void updateSettings(
      {String? name, String? apiKey, String? model, LlmProvider? provider}) {
    if (name != null) displayName = name.trim();
    if (apiKey != null) ai.apiKey = apiKey.trim();
    if (provider != null && provider != ai.provider) {
      ai.provider = provider;
      ai.model = provider.defaultModel;
    }
    if (model != null && model.trim().isNotEmpty) ai.model = model.trim();
    _changed();
  }

  void updateNudges(void Function(NudgeSettings n) edit) {
    edit(nudges);
    screen.pushSettings(nudges);
    _changed();
  }

  void completeOnboarding(String name) {
    displayName = name.trim();
    onboarded = true;
    _changed();
  }

  void clearAll() {
    logs.clear();
    chat.clear();
    weeklySummary = null;
    weeklySummaryAt = null;
    _changed();
  }

  /// Anonymised export for analysis (thesis 3.8): no name, no API key.
  String exportJson() => const JsonEncoder.withIndent('  ').convert({
        'logs': logs.map((e) => e.toJson()).toList(),
        if (features.screen != null) 'screen_time_7d': features.screen!.toPromptJson(),
      });

  /// Simulated records for prototyping/demos (thesis 3.4.6), flagged synthetic.
  void seedDemoData() {
    final rnd = Random(42);
    final now = DateTime.now();
    final profiles = [
      (Trigger.boredom, 14, 3, 2),
      (Trigger.stress, 21, 4, 4),
      (Trigger.lateNight, 0, 4, 3),
      (Trigger.avoidance, 16, 3, 4),
      (Trigger.urge, 10, 3, 2),
      (Trigger.reward, 22, 3, 2),
    ];
    for (var d = 13; d >= 0; d--) {
      final n = 1 + rnd.nextInt(d < 7 ? 4 : 3);
      for (var k = 0; k < n; k++) {
        final p = profiles[rnd.nextInt(profiles.length)];
        final day = now.subtract(Duration(days: d));
        var at = DateTime(day.year, day.month, day.day,
            (p.$2 + rnd.nextInt(3)) % 24, rnd.nextInt(60));
        if (p.$2 == 0) at = at.add(const Duration(days: 1));
        if (at.isAfter(now)) continue;
        logs.add(LogEntry(
          id: _uuid.v4(),
          timestamp: at,
          kind: EntryKind.episode,
          mood: (p.$3 - rnd.nextInt(2)).clamp(1, 5),
          stress: (p.$4 + rnd.nextInt(2)).clamp(1, 5),
          craving: 2 + rnd.nextInt(4),
          triggers: [p.$1],
          durationMinutes: 5 + rnd.nextInt(60),
          resisted: rnd.nextDouble() < 0.3,
          note: '',
          synthetic: true,
        ));
      }
    }
    _changed();
  }

  int get syntheticCount => logs.where((l) => l.synthetic).length;

  void removeSynthetic() {
    logs.removeWhere((l) => l.synthetic);
    _changed();
  }
}
