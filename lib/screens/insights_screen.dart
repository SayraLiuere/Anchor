import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../services/app_state.dart';
import '../services/risk_model.dart';
import '../widgets/common.dart';

/// Weekly recap + simple dashboards (FR5, FR6, thesis 4.9).
class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final f = s.features;
    final t = Theme.of(context);

    // Episodes by hour block over the window.
    final start = DateTime.now().subtract(Duration(days: f.windowDays));
    final blocks = List<int>.filled(6, 0); // 4-hour blocks
    for (final l in s.logs) {
      if (l.kind == EntryKind.episode && l.timestamp.isAfter(start)) {
        blocks[l.timestamp.hour ~/ 4]++;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          // Weekly recap from the LLM
          const SectionTitle('Weekly recap'),
          Card(
            color: t.colorScheme.primaryContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const MiraAvatar(size: 32, mood: PetMood.calm),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.weeklySummaryAt == null
                            ? 'Ask Mira to look back on your week'
                            : 'Written ${DateFormat('EEE d MMM, h:mm a').format(s.weeklySummaryAt!)}',
                        style: t.textTheme.labelMedium,
                      ),
                    ),
                  ]),
                  if (s.weeklySummary != null) ...[
                    const SizedBox(height: 12),
                    RecapText(s.weeklySummary!),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: s.companionTyping
                          ? null
                          : () => s.generateWeeklySummary(),
                      icon: s.companionTyping
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.auto_awesome),
                      label: Text(s.weeklySummary == null
                          ? 'Generate recap'
                          : 'Refresh recap'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SectionTitle('Last 7 days'),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: [
              StatTile(
                  label: 'Episodes / day',
                  value: f.episodesPerDay.toStringAsFixed(1),
                  icon: Icons.phone_android),
              StatTile(
                  label: 'Late-night share',
                  value: '${(f.lateNightRatio * 100).round()}%',
                  icon: Icons.bedtime_outlined),
              StatTile(
                  label: 'Urges resisted',
                  value: '${(f.resistRate * 100).round()}%',
                  icon: Icons.shield_outlined),
              StatTile(
                  label: 'Avg stress',
                  value: f.meanStress == 0 ? '–' : f.meanStress.toStringAsFixed(1),
                  icon: Icons.bolt),
            ],
          ),

          const SectionTitle('Episodes per day'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
              child: _BarChart(
                values: f.dailyEpisodes,
                labels: List.generate(f.windowDays, (i) {
                  final d = DateTime.now()
                      .subtract(Duration(days: f.windowDays - 1 - i));
                  return DateFormat('E').format(d).substring(0, 2);
                }),
                color: riskColor(s.risk.level),
              ),
            ),
          ),

          const SectionTitle('When it happens'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
              child: _BarChart(
                values: blocks,
                labels: const ['12a', '4a', '8a', '12p', '4p', '8p'],
                color: t.colorScheme.tertiary,
              ),
            ),
          ),

          const SectionTitle('Top triggers'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: f.triggerCounts.isEmpty
                  ? const Text('No triggers logged this week.')
                  : _TriggerBars(counts: f.triggerCounts),
            ),
          ),

          const SectionTitle('How the risk is estimated'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Current model: ${s.risk.modelName}. Score ${(s.risk.score * 100).round()}/100 → '
                '${s.risk.level.label}. Indicators come only from what you log '
                '(episodes per day, late-night share, urge and stress levels, '
                'notification-driven episodes, and how often you resist). '
                'This is an estimate for reflection, not a diagnosis.',
                style: t.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart(
      {required this.values, required this.labels, required this.color});

  final List<int> values;
  final List<String> labels;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final maxV = values.fold(1, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(values.length, (i) {
          final frac = values[i] / maxV;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('${values[i]}', style: t.textTheme.labelSmall),
                  const SizedBox(height: 4),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: frac),
                    duration: const Duration(milliseconds: 600),
                    builder: (_, v, __) => Container(
                      height: 4 + 96 * v,
                      decoration: BoxDecoration(
                        color: values[i] == 0
                            ? t.colorScheme.surfaceContainerHighest
                            : color.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(labels[i], style: t.textTheme.labelSmall),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _TriggerBars extends StatelessWidget {
  const _TriggerBars({required this.counts});

  final Map<Trigger, int> counts;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = sorted.fold(0, (a, e) => a + e.value);
    return Column(
      children: sorted
          .map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(children: [
                  Icon(e.key.icon, size: 18, color: t.colorScheme.primary),
                  const SizedBox(width: 8),
                  SizedBox(
                      width: 120,
                      child: Text(e.key.label, style: t.textTheme.bodySmall)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: e.value / total,
                        minHeight: 10,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(e.value / total * 100).round()}%',
                      style: t.textTheme.labelSmall),
                ]),
              ))
          .toList(),
    );
  }
}

/// Renders the professional recap, bolding its section headings.
class RecapText extends StatelessWidget {
  const RecapText(this.text, {super.key});

  final String text;

  static final _heading =
      RegExp(r'^\**#*\s*(Overview|Patterns|Suggestions)\s*:?\**\s*$', caseSensitive: false);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in text.split('\n'))
          if (_heading.hasMatch(line.trim()))
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Text(_heading.firstMatch(line.trim())!.group(1)!,
                  style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            )
          else if (line.trim().isNotEmpty)
            Text(line.replaceAll('**', '').replaceFirst(RegExp(r'^\s*[-*]\s+'), '•  ')),
      ],
    );
  }
}
