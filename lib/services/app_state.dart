import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/log_entry.dart';
import 'baseline.dart';
import 'chat_context.dart';
import 'companion_ai.dart';
import 'export.dart';
import 'memory.dart';
import '../models/fact.dart';
import 'features.dart';
import 'risk_model.dart';
import '../models/schedule_block.dart';
import 'schedule_service.dart';
import 'screen_time.dart';
import 'secret_store.dart';
import 'usage_snapshots.dart';

/// Mira's pet mood, shown on her face and in her lines.
enum PetMood { happy, calm, excited, worried, sleepy }

/// Data layer + glue between the four architecture layers (thesis 4.3).
/// Everything is kept on-device in a single JSON file.
class AppState extends ChangeNotifier {
  final _uuid = const Uuid();
  final ai = CompanionAI();
  final screen = ScreenTimeService();

  RiskEngine riskEngine = RiskEngine();

  /// Version of second_brain.json. Old files have no field and load with
  /// defaults; keys are only ever added, never renamed or removed.
  /// v2 (A2): adds usage_daily and usage_hourly.
  /// v3 (A3): timestamps carry their UTC offset; day rows get day_start.
  /// v4 (B1): adds install_id; apiKey moves to secure storage (kept in the
  /// file only if secure storage fails).
  /// v5 (C1): adds blocks; logs get block_id and block_type.
  /// v6 (B4): adds facts.
  static const schemaVersion = 6;

  /// True when the bundled Random Forest loaded (used with screen time on).
  bool get forestAvailable => riskEngine.forest != null;
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

  /// Saved complete days and their hourly breakdown (A2). Never overwritten.
  List<DaySnapshot> usageDaily = [];
  List<HourUsage> usageHourly = [];

  /// Schedule blocks (C1). Stored as `blocks`.
  List<ScheduleBlock> blocks = [];
  ScheduleService get schedule => ScheduleService(blocks);

  /// Set when a notification was tapped ("log" or "checkin"); the UI consumes it.
  String? pendingAction;

  late BehaviourFeatures features;
  late RiskResult risk;

  File? _file;

  final secrets = SecretStore();

  /// Random ID made on first launch (B1), sent to the proxy for its daily
  /// limit. Stored as install_id; not in the export.
  String installId = '';

  /// False only when secure storage failed, so the key stays in the JSON.
  bool _keyInSecureStorage = true;

  Future<void> init() async {
    riskEngine = await RiskEngine.load();
    String? savedProvider, savedModel;
    var jsonKey = '';
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
        savedProvider = j['provider'] as String?;
        savedModel = j['model'] as String?;
        jsonKey = j['apiKey'] as String? ?? '';
        installId = j['install_id'] as String? ?? '';
        weeklySummary = j['weeklySummary'] as String?;
        final at = j['weeklySummaryAt'] as String?;
        weeklySummaryAt = at == null ? null : parseTimestamp(at);
        onboarded = j['onboarded'] as bool? ?? false;
        if (j['nudges'] != null) {
          nudges = NudgeSettings.fromJson(j['nudges'] as Map<String, dynamic>);
        }
        if (j['dismissedDrafts'] != null) {
          dismissedDrafts = (j['dismissedDrafts'] as List).cast<String>().toSet();
        }
        usageDaily = (j['usage_daily'] as List? ?? [])
            .map((e) => DaySnapshot.fromJson(e as Map<String, dynamic>))
            .toList();
        final dismissedAt = j['limit_suggestion_dismissed_at'] as String?;
        limitSuggestionDismissedAt = dismissedAt == null ? null : parseTimestamp(dismissedAt);
        facts = (j['facts'] as List? ?? [])
            .map((e) => Fact.fromJson(e as Map<String, dynamic>))
            .toList();
        blocks = (j['blocks'] as List? ?? [])
            .map((e) => ScheduleBlock.fromJson(e as Map<String, dynamic>))
            .toList();
        usageHourly = (j['usage_hourly'] as List? ?? [])
            .map((e) => HourUsage.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('Failed to load data: $e');
    }
    final needsSave = await _loadAiSettings(savedProvider, savedModel, jsonKey);
    screen.onLaunchAction = (a) {
      pendingAction = a;
      notifyListeners();
    };
    pendingAction = await screen.takeLaunchAction();
    _recompute();
    loading = false;
    notifyListeners();
    if (needsSave) await _save();
    await screen.pushSettings(nudges);
    await screen.pushSchedule(blocks);
    await refreshDevice();
  }

  /// B1: the Anchor proxy is the default; a developer key moves from the
  /// JSON into secure storage (it stays in the JSON only if that fails);
  /// a random install ID is made once. Returns true when the file must be
  /// saved again (new ID, or a key to drop from the JSON).
  Future<bool> _loadAiSettings(String? savedProvider, String? savedModel, String jsonKey) async {
    var changed = false;
    if (jsonKey.isNotEmpty) {
      ai.apiKey = jsonKey;
      _keyInSecureStorage = await secrets.writeApiKey(jsonKey);
      changed = _keyInSecureStorage;
    } else {
      ai.apiKey = await secrets.readApiKey() ?? '';
    }
    ai.provider = providerAfterLoad(savedProvider, hasKey: ai.apiKey.isNotEmpty);
    ai.model = ai.provider == LlmProvider.proxy
        ? ai.provider.defaultModel
        : savedModel ?? ai.provider.defaultModel;
    if (installId.isEmpty) {
      installId = _uuid.v4();
      changed = true;
    }
    ai.installId = installId;
    return changed;
  }

  /// Re-reads permissions and screen time. Called on start and app resume.
  Future<void> refreshDevice() async {
    usageGranted = await screen.hasUsagePermission();
    notificationsGranted = await screen.hasNotificationPermission();
    if (usageGranted) {
      try {
        todayUsage = await screen.today();
        await _backfillSnapshots();
        weekUsage = usageDaily.isEmpty
            ? await screen.daily(days: 7)
            : weekFromSnapshots(usageDaily, todayUsage, DateTime.now());
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

  bool _backfilling = false;

  /// Saves any of the last 7 complete days that have no row yet (A2). One read
  /// covers them all, starting 3 h early to catch sessions that cross
  /// midnight. Days with no usage at all are skipped (likely outside Android's
  /// event history) and retried next time. Today is saved once it is complete.
  Future<void> _backfillSnapshots() async {
    if (_backfilling) return; // a refresh on resume can overlap the one in init
    _backfilling = true;
    try {
      final now = DateTime.now();
      final missing = missingDays(usageDaily.map((d) => d.date), now);
      if (missing.isEmpty) return;
      final read = await screen.sessions(
          DateTime.parse(missing.first).subtract(const Duration(hours: 3)),
          dayOf(now));
      if (read == null) return;
      final built = buildSnapshots(read.sessions, read.unlocks, missing);
      final have = usageDaily.map((d) => d.date).toSet();
      final add = built.days
          .where((d) => !have.contains(d.date) && (d.totalMinutes > 0 || d.unlocks > 0))
          .toList();
      if (add.isEmpty) return;
      final added = add.map((d) => d.date).toSet();
      usageDaily = [...usageDaily, ...add]..sort((a, b) => a.date.compareTo(b.date));
      usageHourly.addAll(built.hours.where((h) => added.contains(h.date)));
      await _save();
    } finally {
      _backfilling = false;
    }
  }

  void _recompute() {
    logs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    features = BehaviourFeatures.fromLogs(logs,
        screen: usageGranted ? ScreenTimeFeatures.fromDaily(weekUsage) : null);
    final predicted = riskEngine.predict(features);
    // C2: compare today with the user's usual; big rises become reasons.
    baseline = Baseline.from(usageDaily, usageHourly);
    deviationsToday = baseline != null && usageGranted && todayUsage != null
        ? baseline!.compareToday(todayUsage!, DateTime.now())
        : const [];
    final extra = deviationReasons(deviationsToday);
    risk = extra.isEmpty
        ? predicted
        : RiskResult(predicted.level, predicted.score, [...predicted.reasons, ...extra],
            predicted.modelName);
  }

  // ---------- Personal baseline (C2) ----------

  /// Null until there are 7 saved days.
  Baseline? baseline;

  /// Today so far against the usual by the same time of day.
  List<Deviation> deviationsToday = const [];

  /// When the user last said "Not now" to suggested limits (hidden 7 days).
  DateTime? limitSuggestionDismissedAt;

  /// Suggested limits that differ from the current ones by 5+ minutes;
  /// empty when there is nothing to offer.
  Map<String, int> get limitSuggestions {
    final b = baseline;
    final dismissed = limitSuggestionDismissedAt;
    if (b == null ||
        (dismissed != null && DateTime.now().difference(dismissed).inDays < 7)) {
      return const {};
    }
    return {
      for (final e in b.suggestedLimits().entries)
        if (((nudges.limits[e.key] ?? 0) - e.value).abs() >= 5) e.key: e.value,
    };
  }

  void acceptSuggestedLimits(Map<String, int> limits) =>
      updateNudges((n) => n.limits.addAll(limits));

  void dismissSuggestedLimits() {
    limitSuggestionDismissedAt = DateTime.now();
    _changed();
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
      // B1: the key lives in secure storage; here only if that failed.
      if (!_keyInSecureStorage && ai.apiKey.isNotEmpty) 'apiKey': ai.apiKey,
      'install_id': installId,
      'model': ai.model,
      'weeklySummary': weeklySummary,
      'weeklySummaryAt': weeklySummaryAt == null ? null : toOffsetIso(weeklySummaryAt!),
      'schema_version': schemaVersion,
      'onboarded': onboarded,
      'nudges': nudges.toJson(),
      'dismissedDrafts': dismissedDrafts.toList(),
      'usage_daily': usageDaily.map((e) => e.toJson()).toList(),
      'usage_hourly': usageHourly.map((e) => e.toJson()).toList(),
      'blocks': blocks.map((b) => b.toJson()).toList(),
      'facts': facts.map((f) => f.toJson()).toList(),
      if (limitSuggestionDismissedAt != null)
        'limit_suggestion_dismissed_at': toOffsetIso(limitSuggestionDismissedAt!),
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
    final when = at ?? DateTime.now();
    // C1: label the log with the block running at that time. A drafted
    // session is labelled by when it started, not when it was confirmed.
    final tag = schedule.tagFor(draft?.start ?? when);
    final entry = LogEntry(
      id: _uuid.v4(),
      timestamp: when,
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
      appGroup: draft?.group,
      draftId: draft?.id,
      blockId: tag?.$1,
      blockType: tag?.$2,
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
    final now = DateTime.now();
    final scrubber = promptScrubber;
    final answer = await ai.reply(
      userText: text,
      features: features,
      risk: risk,
      history: chat.sublist(0, chat.length - 1),
      context: {
        ...buildChatContext(
          now: now,
          features: features,
          risk: risk,
          logs: logs,
          today: usageGranted ? todayUsage : null,
          schedule: schedule,
          deviations: deviationsToday,
        ),
        'remembered': factsForPrompt(relevantFacts(now), scrubber),
      },
      scrubber: scrubber,
    );
    chat.add(ChatMessage(fromUser: false, text: answer.text));
    // B4: suggestions wait for a tap; nothing is saved here.
    final known = facts.map((f) => f.text.toLowerCase()).toSet();
    pendingFacts = answer.facts.where((f) => !known.contains(f.text.toLowerCase())).toList();
    companionTyping = false;
    notifyListeners();
    _save();
  }

  // ---------- Long-term memory (B4) ----------

  /// Facts the user confirmed. Stored as `facts`.
  List<Fact> facts = [];

  /// Facts Mira suggested in her last reply, waiting for a tap. Not saved.
  List<SuggestedFact> pendingFacts = [];

  /// The facts sent with a chat message: matching the latest trigger (if
  /// logged in the last 3 hours, else the week's top trigger), the current
  /// block or the time of day, then newest.
  List<Fact> relevantFacts(DateTime now) {
    final recent = logs
        .where((l) => l.triggers.isNotEmpty && now.difference(l.timestamp).inHours < 3)
        .firstOrNull;
    return selectFacts(
      facts,
      now: now,
      trigger: recent?.triggers.first ?? features.topTrigger,
      blockType: schedule.currentBlock(now)?.type.id,
    );
  }

  void confirmFact(SuggestedFact s) {
    final now = DateTime.now();
    facts.add(Fact(
      id: _uuid.v4(),
      text: s.text,
      category: s.category,
      private: s.private,
      createdAt: now,
    ));
    pendingFacts.remove(s);
    _changed();
  }

  void dismissSuggestion(SuggestedFact s) {
    pendingFacts.remove(s);
    notifyListeners();
  }

  void addFact(String text, FactCategory category, {bool private = false}) {
    facts.add(Fact(
      id: _uuid.v4(),
      text: text.trim(),
      category: category,
      private: private,
      source: FactSource.manual,
      createdAt: DateTime.now(),
    ));
    _changed();
  }

  void updateFact(Fact f) {
    final i = facts.indexWhere((x) => x.id == f.id);
    if (i >= 0) facts[i] = f.copyWith(lastConfirmed: DateTime.now());
    _changed();
  }

  /// Deleting a fact removes it from every later prompt.
  void deleteFact(String id) {
    facts.removeWhere((f) => f.id == id);
    _changed();
  }

  /// Every app name and the display name Mira's AI must not see (B2):
  /// apps used today, apps of drafted sessions and logged episodes.
  PromptScrubber get promptScrubber => PromptScrubber(
        displayName: displayName,
        appGroups: {
          for (final l in logs)
            if (l.appLabel != null) l.appLabel!: l.appGroup,
          for (final d in _sessions) d.label: d.group,
          for (final a in todayUsage?.apps ?? const <AppUsageInfo>[]) a.label: a.group,
        },
      );

  /// Short companion acknowledgement after a log is saved (thesis 4.7).
  /// Says the app's group, not its name, and never includes the note (B2).
  Future<void> reactToLog(LogEntry e) async {
    final desc = StringBuffer(e.kind != EntryKind.episode
        ? 'Quick check-in'
        : e.autoDetected
            ? 'You noticed I spent ${e.durationMinutes} min on ${groupPhrase(e.appGroup)}'
            : 'I just logged a phone episode');
    if (e.triggers.isNotEmpty) {
      desc.write(' (${e.triggers.map((t) => t.label.toLowerCase()).join(', ')})');
    }
    if (e.kind == EntryKind.episode) {
      desc.write(e.resisted ? ' and I managed to resist.' : ', about ${e.durationMinutes} min.');
    }
    desc.write(' Mood ${e.mood}/5, stress ${e.stress}/5, urge ${e.craving}/5.');
    await sendToCompanion(desc.toString());
  }

  void clearChat() {
    chat.clear();
    _changed();
  }

  Future<void> generateWeeklySummary() async {
    companionTyping = true;
    notifyListeners();
    weeklySummary = await ai.weeklySummary(features, risk,
        context: buildRecapContext(
          now: DateTime.now(),
          features: features,
          risk: risk,
          week: usageGranted ? weekUsage : const [],
          baseline: baseline,
        ));
    weeklySummaryAt = DateTime.now();
    companionTyping = false;
    _changed();
  }

  // ---------- Settings ----------

  void updateSettings(
      {String? name, String? apiKey, String? model, LlmProvider? provider}) {
    if (name != null) displayName = name.trim();
    if (apiKey != null && apiKey.trim() != ai.apiKey) {
      ai.apiKey = apiKey.trim();
      secrets.writeApiKey(ai.apiKey).then((ok) {
        if (ok != _keyInSecureStorage) {
          _keyInSecureStorage = ok;
          _save();
        }
      });
    }
    if (provider != null && provider != ai.provider) {
      ai.provider = provider;
      ai.model = provider.defaultModel;
    }
    if (model != null && model.trim().isNotEmpty) ai.model = model.trim();
    _changed();
  }

  // ---------- Schedule (C1) ----------

  /// Adds or replaces a block (matched by id).
  void saveBlock(ScheduleBlock b) {
    final i = blocks.indexWhere((x) => x.id == b.id);
    if (i >= 0) {
      blocks[i] = b;
    } else {
      blocks.add(b);
    }
    _scheduleChanged();
  }

  /// Deletes a block; blocks inside a deleted folder stay, moved out of it.
  void deleteBlock(String id) {
    blocks = [
      for (final b in blocks)
        if (b.id != id) b.parentId == id ? b.copyWith(clearParent: true) : b,
    ];
    _scheduleChanged();
  }

  /// Skips a block just for [day] ("Not today").
  void cancelBlockOn(String id, DateTime day) {
    final i = blocks.indexWhere((x) => x.id == id);
    if (i < 0) return;
    blocks[i] = blocks[i].copyWith(
        cancelledDates: {...blocks[i].cancelledDates, dateKey(day)});
    _scheduleChanged();
  }

  String newBlockId() => _uuid.v4();

  void _scheduleChanged() {
    screen.pushSchedule(blocks);
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
    facts.clear();
    pendingFacts.clear();
    _changed();
  }

  /// Export v2 for analysis (E2, thesis 3.8): saved daily and hourly screen
  /// time, logs and nudges. No name, chat or API key.
  Future<String> exportJson() async => encodeExport(buildExport(
        now: DateTime.now(),
        appVersion: await screen.appVersion(),
        daily: usageDaily,
        hourly: usageHourly,
        logs: logs,
      ));

  /// Writes the export to a temporary file for the share sheet.
  Future<File> writeExportFile() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${exportFileName(DateTime.now())}');
    return f.writeAsString(await exportJson(), flush: true);
  }

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
