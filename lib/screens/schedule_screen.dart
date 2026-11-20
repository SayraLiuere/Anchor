import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/schedule_block.dart';
import '../services/app_state.dart';
import '../services/schedule_service.dart';
import '../widgets/common.dart';

const _dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

String _hm(DateTime t) => DateFormat('HH:mm').format(t);

String _weekdaysText(Set<int> days) {
  if (days.length == 7) return 'Every day';
  if (days.length == 5 && days.containsAll({1, 2, 3, 4, 5})) return 'Weekdays';
  if (days.length == 2 && days.containsAll({6, 7})) return 'Weekends';
  final sorted = days.toList()..sort();
  return sorted.map((d) => DateFormat('E').format(DateTime(2026, 11, 15 + d))).join(', ');
}

/// Today's schedule (C1, FR15–FR17, thesis 3.5.6): blocks in time order,
/// child blocks nested in their folder, and the free gaps inside a folder.
class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context);
    final now = DateTime.now();
    final svc = s.schedule;
    final today = svc.occurrencesTouching(now);
    final gaps = svc.gapsTouching(now);
    final current = svc.currentOccurrence(now);
    final load = svc.todayLoad(now);
    // An occurrence is one block on one day; last night's and tonight's
    // sleep are different occurrences of the same block.
    bool same(BlockOccurrence? a, BlockOccurrence b) =>
        a != null && a.block.id == b.block.id && a.start == b.start;
    bool inside(BlockOccurrence f, DateTime t) => !t.isBefore(f.start) && t.isBefore(f.end);
    final folders = today.where((o) => o.block.type == BlockType.folder).toList();
    final topLevel = today.where((o) => !folders.any(
        (f) => f.block.id == o.block.parentId && inside(f, o.start)));

    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openBlockSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Add block'),
      ),
      body: s.blocks.isEmpty && s.notesOn(now).isEmpty
          ? const _EmptySchedule()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                Row(children: [
                  Text(DateFormat('EEEE d MMM').format(now), style: t.textTheme.titleMedium),
                  const Spacer(),
                  Chip(
                    avatar: const Icon(Icons.speed, size: 18),
                    label: Text('${load.label.label} day'
                        '${load.busyHours > 0 ? ' · ${load.busyHours.toStringAsFixed(1)}h busy' : ''}'),
                  ),
                ]),
                const SizedBox(height: 8),
                // C3: notes about today, as chips; tap x to remove.
                if (s.notesOn(now).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final n in s.notesOn(now))
                        InputChip(
                          avatar: Icon(n.private ? Icons.lock_outline : n.type.icon, size: 18),
                          label: Text(n.label +
                              (n.blockId == null
                                  ? ''
                                  : ' · ${s.blocks.where((b) => b.id == n.blockId).firstOrNull?.title ?? 'a block'}')),
                          onDeleted: () => s.deleteNote(n.id),
                        ),
                    ]),
                  ),
                if (today.isEmpty)
                  const Card(child: ListTile(title: Text('Nothing scheduled today'))),
                for (final o in topLevel)
                  o.block.type == BlockType.folder
                      ? _FolderCard(
                          folder: o,
                          children: today
                              .where((c) => c.block.parentId == o.block.id && inside(o, c.start))
                              .toList(),
                          gaps: gaps
                              .where((g) => g.folder.id == o.block.id && inside(o, g.start))
                              .toList(),
                          current: current,
                          now: now,
                        )
                      : Card(child: _BlockTile(o, isNow: same(current, o))),
                if (s.blocks.isNotEmpty) const SectionTitle('All blocks'),
                if (s.blocks.isNotEmpty) Card(
                  child: Column(children: [
                    for (final b in [...s.blocks]..sort((a, b) => a.start.compareTo(b.start)))
                      ListTile(
                        dense: true,
                        leading: Icon(b.type.icon),
                        title: Text(b.title),
                        subtitle: Text('${formatHm(b.start)}–${formatHm(b.end)} · '
                            '${_weekdaysText(b.weekdays)}'
                            '${b.parentId != null ? ' · in ${s.blocks.where((f) => f.id == b.parentId).firstOrNull?.title ?? 'a folder'}' : ''}'),
                        trailing: b.quiet ? const Icon(Icons.notifications_off_outlined, size: 18) : null,
                        onTap: () => openBlockSheet(context, block: b),
                      ),
                  ]),
                ),
              ],
            ),
    );
  }
}

class _EmptySchedule extends StatelessWidget {
  const _EmptySchedule();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const MiraAvatar(size: 72, mood: PetMood.excited),
          const SizedBox(height: 12),
          Text('Tell Mira your week', style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Add classes, study time, work and sleep. A folder like "On campus" can hold '
            'your classes; the time between them shows as free. Mira uses this to '
            'understand when your phone pulls you in.',
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.children,
    required this.gaps,
    required this.current,
    required this.now,
  });

  final BlockOccurrence folder;
  final List<BlockOccurrence> children;
  final List<FreeGap> gaps;
  final BlockOccurrence? current;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final rows = <(DateTime, Widget)>[
      for (final c in children)
        (c.start, _BlockTile(c, isNow: current != null && current!.block.id == c.block.id && current!.start == c.start, indent: true)),
      for (final g in gaps)
        (
          g.start,
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 40, right: 16),
            leading: Icon(Icons.free_breakfast_outlined, color: t.colorScheme.outline),
            title: Text('${folder.block.title}, free',
                style: TextStyle(color: t.colorScheme.outline, fontStyle: FontStyle.italic)),
            subtitle: Text('${_hm(g.start)}–${_hm(g.end)}'),
            tileColor: !now.isBefore(g.start) && now.isBefore(g.end)
                ? t.colorScheme.primaryContainer.withValues(alpha: 0.4)
                : null,
          ),
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return Card(
      child: Column(children: [
        _BlockTile(folder, isNow: false),
        ...rows.map((r) => r.$2),
      ]),
    );
  }
}

class _BlockTile extends StatelessWidget {
  const _BlockTile(this.o, {required this.isNow, this.indent = false});

  final BlockOccurrence o;
  final bool isNow;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppState>();
    final b = o.block;
    final now = DateTime.now();
    final fromLastNight = o.start.isBefore(DateTime(now.year, now.month, now.day));
    return ListTile(
      contentPadding: EdgeInsets.only(left: indent ? 40 : 16, right: 4),
      tileColor: isNow ? t.colorScheme.primaryContainer.withValues(alpha: 0.6) : null,
      leading: Icon(b.type.icon),
      title: Text(b.title, style: b.type == BlockType.folder
          ? t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)
          : null),
      subtitle: Text('${fromLastNight ? 'From last night · ' : ''}'
          '${_hm(o.start)}–${_hm(o.end)} · ${b.type.label}'
          '${isNow ? ' · now' : ''}'),
      onTap: () => openBlockSheet(context, block: b),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (b.quiet) const Icon(Icons.notifications_off_outlined, size: 18),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'edit') openBlockSheet(context, block: b);
            if (v == 'skip') s.cancelBlockOn(b.id, o.start);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'skip', child: Text('Not today')),
          ],
        ),
      ]),
    );
  }
}

/// Add or edit a block: title, type, times, weekdays, folder, quiet.
Future<void> openBlockSheet(BuildContext context, {ScheduleBlock? block}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BlockForm(block: block),
    );

class BlockForm extends StatefulWidget {
  const BlockForm({super.key, this.block});

  final ScheduleBlock? block;

  @override
  State<BlockForm> createState() => _BlockFormState();
}

class _BlockFormState extends State<BlockForm> {
  late final s = context.read<AppState>();
  late final _title = TextEditingController(text: widget.block?.title ?? '');
  late BlockType _type = widget.block?.type ?? BlockType.classBlock;
  late int _start = widget.block?.start ?? 9 * 60;
  late int _end = widget.block?.end ?? 10 * 60;
  late final Set<int> _days = {...(widget.block?.weekdays ?? const {1, 2, 3, 4, 5})};
  late String? _parent = widget.block?.parentId;
  late bool _quiet = widget.block?.quiet ?? false;
  String? _error;

  List<ScheduleBlock> get _folders => s.blocks
      .where((b) => b.type == BlockType.folder && b.id != widget.block?.id)
      .toList();

  Future<void> _pick(bool start) async {
    final m = start ? _start : _end;
    final picked = await showTimePicker(
        context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (picked == null) return;
    setState(() {
      final v = picked.hour * 60 + picked.minute;
      start ? _start = v : _end = v;
    });
  }

  /// Returns an error message, or null when the block can be saved.
  String? _validate() {
    if (_title.text.trim().isEmpty) return 'Give it a name';
    if (_start == _end) return 'Start and end must differ';
    if (_days.isEmpty) return 'Pick at least one day';
    final folder = _folders.where((f) => f.id == _parent).firstOrNull;
    if (folder != null && !folder.crossesMidnight) {
      final crosses = _end <= _start;
      if (crosses || _start < folder.start || _end > folder.end) {
        return 'Must fit inside ${folder.title} (${formatHm(folder.start)}–${formatHm(folder.end)})';
      }
    }
    return null;
  }

  void _save() {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final isFolder = _type == BlockType.folder;
    s.saveBlock(ScheduleBlock(
      id: widget.block?.id ?? s.newBlockId(),
      title: _title.text.trim(),
      type: _type,
      start: _start,
      end: _end,
      weekdays: _days,
      parentId: isFolder ? null : _parent,
      quiet: _quiet,
      cancelledDates: widget.block?.cancelledDates,
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final editing = widget.block != null;
    final folders = _folders;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(editing ? 'Edit block' : 'New block', style: t.textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Data Structures lecture'),
          ),
          const SizedBox(height: 16),
          Text('Type', style: t.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final ty in BlockType.values)
              ChoiceChip(
                avatar: Icon(ty.icon, size: 18),
                label: Text(ty.label),
                selected: _type == ty,
                onSelected: (_) => setState(() => _type = ty),
              ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pick(true),
                icon: const Icon(Icons.schedule),
                label: Text('Starts ${formatHm(_start)}'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pick(false),
                icon: const Icon(Icons.schedule),
                label: Text('Ends ${formatHm(_end)}'),
              ),
            ),
          ]),
          if (_end <= _start && _start != _end)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Ends the next morning', style: t.textTheme.bodySmall),
            ),
          const SizedBox(height: 16),
          Text('Repeats on', style: t.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (var d = 1; d <= 7; d++)
              FilterChip(
                label: Text(_dayLetters[d - 1]),
                selected: _days.contains(d),
                showCheckmark: false,
                onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
              ),
          ]),
          if (_type != BlockType.folder && folders.isNotEmpty) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              value: folders.any((f) => f.id == _parent) ? _parent : null,
              decoration: const InputDecoration(labelText: 'Inside folder'),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                for (final f in folders)
                  DropdownMenuItem(
                      value: f.id,
                      child: Text('${f.title} (${formatHm(f.start)}–${formatHm(f.end)})')),
              ],
              onChanged: (v) => setState(() => _parent = v),
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Quiet'),
            subtitle: const Text('No nudges from Mira during this block'),
            value: _quiet,
            onChanged: (v) => setState(() => _quiet = v),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
            ),
          Row(children: [
            if (editing)
              TextButton.icon(
                onPressed: () {
                  s.deleteBlock(widget.block!.id);
                  Navigator.pop(context);
                },
                icon: Icon(Icons.delete_outline, color: t.colorScheme.error),
                label: Text('Delete', style: TextStyle(color: t.colorScheme.error)),
              ),
            const Spacer(),
            FilledButton(onPressed: _save, child: Text(editing ? 'Save' : 'Add')),
          ]),
        ]),
      ),
    );
  }
}
