import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/fact.dart';
import '../services/app_state.dart';

/// "What Mira remembers" (B4, FR22-FR24): every confirmed fact, with edit
/// and delete. Deleting a fact removes it from all later prompts.
class RememberedScreen extends StatelessWidget {
  const RememberedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context);
    final facts = [...s.facts]..sort((a, b) => b.lastConfirmed.compareTo(a.lastConfirmed));
    return Scaffold(
      appBar: AppBar(title: const Text('What Mira remembers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editFact(context),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            'Mira only remembers what you confirm. The most relevant of these go into her '
            'replies; private ones are never shared, she is only told a private note exists.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (facts.isEmpty)
            const Card(
              child: ListTile(
                leading: Icon(Icons.psychology_alt_outlined),
                title: Text('Nothing yet'),
                subtitle: Text('When you tell Mira what helps you or what pulls you in, '
                    'she will ask if she should remember it.'),
              ),
            ),
          for (final f in facts)
            Card(
              child: ListTile(
                leading: Icon(f.category.icon),
                title: Text(f.text),
                subtitle: Text('${f.category.label} · '
                    '${f.source == FactSource.manual ? 'added by you' : 'from chat'} · '
                    '${DateFormat('d MMM').format(f.createdAt)}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (f.private) const Icon(Icons.lock_outline, size: 18),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => s.deleteFact(f.id),
                  ),
                ]),
                onTap: () => _editFact(context, fact: f),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> _editFact(BuildContext context, {Fact? fact}) => showDialog(
      context: context,
      builder: (_) => _FactDialog(fact: fact),
    );

class _FactDialog extends StatefulWidget {
  const _FactDialog({this.fact});

  final Fact? fact;

  @override
  State<_FactDialog> createState() => _FactDialogState();
}

class _FactDialogState extends State<_FactDialog> {
  late final _text = TextEditingController(text: widget.fact?.text ?? '');
  late FactCategory _category = widget.fact?.category ?? FactCategory.whatHelps;
  late bool _private = widget.fact?.private ?? false;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return AlertDialog(
      title: Text(widget.fact == null ? 'Add a memory' : 'Edit memory'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _text,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'e.g. A short walk helps when I\'m stressed'),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final c in FactCategory.values)
              ChoiceChip(
                label: Text(c.label),
                selected: _category == c,
                onSelected: (_) => setState(() => _category = c),
              ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Private'),
            subtitle: const Text('Health or personal: never sent to the AI'),
            value: _private,
            onChanged: (v) => setState(() => _private = v),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final text = _text.text.trim();
            if (text.isEmpty) return;
            if (widget.fact == null) {
              s.addFact(text, _category, private: _private);
            } else {
              s.updateFact(widget.fact!.copyWith(text: text, category: _category, private: _private));
            }
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
