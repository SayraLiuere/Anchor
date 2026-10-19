import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/log_entry.dart';
import '../services/app_state.dart';
import '../services/risk_model.dart';
import '../widgets/common.dart';

Future<void> openLogSheet(BuildContext context, EntryKind kind) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => LogSheet(initialKind: kind),
  ).then((saved) {
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Saved to your memory. Mira is replying…'),
        action: SnackBarAction(
            label: 'View', onPressed: () => RootShell.goTo(context, 1)),
      ));
    }
  });
}

/// Episode / check-in form (FR1, FR2). Kept short: everything is tap-based,
/// only the note is typed.
class LogSheet extends StatefulWidget {
  const LogSheet({super.key, required this.initialKind});

  final EntryKind initialKind;

  @override
  State<LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<LogSheet> {
  late EntryKind _kind = widget.initialKind;
  DateTime _at = DateTime.now();
  int _mood = 3, _stress = 3, _craving = 3;
  double _duration = 15;
  bool _resisted = false;
  final Set<Trigger> _triggers = {};
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    final h = _at.hour;
    if (h >= 23 || h < 5) _triggers.add(Trigger.lateNight);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (t == null) return;
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (at.isAfter(now)) at = at.subtract(const Duration(days: 1));
    setState(() => _at = at);
  }

  void _save() {
    final s = context.read<AppState>();
    final e = s.addLog(
      kind: _kind,
      at: _at,
      mood: _mood,
      stress: _stress,
      craving: _craving,
      triggers: _triggers.toList(),
      durationMinutes: _kind == EntryKind.episode && !_resisted ? _duration.round() : 0,
      resisted: _kind == EntryKind.episode && _resisted,
      note: _note.text.trim(),
    );
    s.reactToLog(e);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isEpisode = _kind == EntryKind.episode;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          SegmentedButton<EntryKind>(
            segments: const [
              ButtonSegment(
                  value: EntryKind.episode,
                  icon: Icon(Icons.phone_android),
                  label: Text('Phone episode')),
              ButtonSegment(
                  value: EntryKind.checkIn,
                  icon: Icon(Icons.favorite_outline),
                  label: Text('Check-in')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text(isEpisode ? 'When did it start?' : 'Time'),
            trailing: TextButton(
                onPressed: _pickTime,
                child: Text(DateFormat('EEE, h:mm a').format(_at))),
          ),
          if (isEpisode) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _resisted,
              onChanged: (v) => setState(() => _resisted = v),
              title: const Text('I felt the urge but resisted'),
              secondary: Icon(_resisted ? Icons.shield : Icons.shield_outlined,
                  color: _resisted ? riskColor(RiskLevel.low) : null),
            ),
            if (!_resisted) ...[
              Text('How long, roughly? ${_duration.round()} min',
                  style: t.textTheme.titleSmall),
              Slider(
                value: _duration,
                min: 5,
                max: 180,
                divisions: 35,
                label: '${_duration.round()} min',
                onChanged: (v) => setState(() => _duration = v),
              ),
            ],
          ],
          const SizedBox(height: 4),
          Text(isEpisode ? 'What pulled you in?' : "What's on your mind?",
              style: t.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: Trigger.values
                .map((tr) => FilterChip(
                      avatar: Icon(tr.icon, size: 18),
                      label: Text(tr.label),
                      selected: _triggers.contains(tr),
                      onSelected: (v) => setState(
                          () => v ? _triggers.add(tr) : _triggers.remove(tr)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 18),
          ScalePicker(
              label: 'Mood',
              value: _mood,
              faces: ScalePicker.moodFaces,
              onChanged: (v) => setState(() => _mood = v)),
          const SizedBox(height: 14),
          ScalePicker(
              label: 'Stress',
              value: _stress,
              faces: ScalePicker.stressFaces,
              onChanged: (v) => setState(() => _stress = v)),
          const SizedBox(height: 14),
          ScalePicker(
              label: 'Urge to check your phone',
              value: _craving,
              faces: ScalePicker.urgeFaces,
              onChanged: (v) => setState(() => _craving = v)),
          const SizedBox(height: 18),
          TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Anything else? (optional) e.g. "avoiding my assignment"',
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: const Text('Save to memory'),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
          ),
        ],
      ),
    );
  }
}
