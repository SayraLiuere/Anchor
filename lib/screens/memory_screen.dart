import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../services/app_state.dart';
import '../services/risk_model.dart';
import '../widgets/common.dart';

/// Memory-style timeline of all logs (FR3, FR6, thesis 4.9).
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  Trigger? _filter;

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return DateFormat('EEEE, d MMM').format(d);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final logs = _filter == null
        ? s.logs
        : s.logs.where((l) => l.triggers.contains(_filter)).toList();

    final groups = <String, List<LogEntry>>{};
    for (final l in logs) {
      groups.putIfAbsent(_dayLabel(l.timestamp), () => []).add(l);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: const Text('All'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                ),
                ...Trigger.values.map((t) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        avatar: Icon(t.icon, size: 16),
                        label: Text(t.label),
                        selected: _filter == t,
                        onSelected: (_) => setState(() => _filter = t),
                      ),
                    )),
              ],
            ),
          ),
          Expanded(
            child: logs.isEmpty
                ? const Center(child: Text('Nothing remembered yet.'))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      for (final g in groups.entries) ...[
                        SectionTitle(g.key,
                            trailing: Text(
                                '${g.value.where((e) => e.kind == EntryKind.episode).length} episodes',
                                style: Theme.of(context).textTheme.labelMedium)),
                        ...g.value.map((e) => _MemoryTile(entry: e)),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = entry;
    final isEp = e.kind == EntryKind.episode;
    final accent = !isEp
        ? t.colorScheme.tertiary
        : e.resisted
            ? riskColor(RiskLevel.low)
            : riskColor(e.craving >= 4 ? RiskLevel.high : RiskLevel.medium);

    return Dismissible(
      key: ValueKey(e.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete_outline, color: t.colorScheme.error),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Forget this entry?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Forget')),
          ],
        ),
      ),
      onDismissed: (_) => context.read<AppState>().deleteLog(e.id),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 48,
                  decoration: BoxDecoration(
                      color: accent, borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(DateFormat('h:mm a').format(e.timestamp),
                            style: t.textTheme.labelLarge),
                        const SizedBox(width: 8),
                        Text(
                          !isEp
                              ? 'Check-in'
                              : e.resisted
                                  ? 'Resisted urge'
                                  : '${e.durationMinutes} min episode',
                          style: t.textTheme.bodySmall,
                        ),
                        const Spacer(),
                        if (e.synthetic)
                          Text('demo',
                              style: t.textTheme.labelSmall
                                  ?.copyWith(color: t.colorScheme.outline)),
                      ]),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        ...e.triggers.map((tr) => _Tag(icon: tr.icon, text: tr.label)),
                        _Tag(text: '${ScalePicker.moodFaces[e.mood - 1]} mood ${e.mood}'),
                        _Tag(text: 'stress ${e.stress}'),
                        _Tag(text: 'urge ${e.craving}'),
                      ]),
                      if (e.note.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('"${e.note}"',
                            style: t.textTheme.bodySmall
                                ?.copyWith(fontStyle: FontStyle.italic)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12), const SizedBox(width: 4)],
        Text(text, style: t.textTheme.labelSmall),
      ]),
    );
  }
}
