import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../models/fact.dart';
import '../models/context_note.dart';
import '../services/app_state.dart';
import '../services/companion_ai.dart';
import '../widgets/common.dart';

/// Companion chat: reflective mini vents with fast tags (FR2, FR5, FR7).
class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key});

  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  static const fastTags = [
    "I'm bored",
    'Stressed about deadlines',
    "Can't sleep, scrolling",
    'Avoiding my work',
    'Just checked out of habit',
    'Feeling good today',
  ];

  void _send(String text) {
    if (text.trim().isEmpty) return;
    _input.clear();
    context.read<AppState>().sendToCompanion(text.trim());
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context);
    _scrollToEnd();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(children: [
          MiraAvatar(size: 36, mood: s.petMood),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Mira'),
            Text(
                !s.ai.online
                    ? 'Offline mode'
                    : s.ai.provider == LlmProvider.proxy
                        ? 'AI companion'
                        : 'AI companion · ${s.ai.model}',
                style: t.textTheme.labelSmall),
          ]),
        ]),
        actions: [
          if (s.chat.isNotEmpty)
            IconButton(
              tooltip: 'Clear conversation',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => s.clearChat(),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: s.chat.isEmpty
                ? _EmptyChat(level: s)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: s.chat.length + (s.companionTyping ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == s.chat.length) return const _TypingBubble();
                      return _Bubble(msg: s.chat[i]);
                    },
                  ),
          ),
          for (final f in s.pendingFacts) _RememberCard(fact: f),
          if (s.pendingNotes.isNotEmpty) _AddNotesCard(key: ValueKey(s.pendingNotes), notes: s.pendingNotes),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: fastTags
                  .map((tag) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                            label: Text(tag),
                            onPressed: s.companionTyping ? null : () => _send(tag)),
                      ))
                  .toList(),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                        hintText: "Vent, reflect, or tell me what's up…",
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                    onSubmitted: _send,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: s.companionTyping ? null : () => _send(_input.text),
                  icon: const Icon(Icons.send),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.level});

  final AppState level;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          MiraAvatar(size: 96, mood: level.petMood),
          const SizedBox(height: 16),
          Text('This is your space to vent',
              style: t.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            "Tell me what's happening when you reach for your phone. "
            "I'll use what you've logged to reflect it back to you.",
            textAlign: TextAlign.center,
            style: t.textTheme.bodyMedium,
          ),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg});

  final ChatMessage msg;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final me = msg.fromUser;
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: me ? t.colorScheme.primary : t.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(me ? 18 : 4),
            bottomRight: Radius.circular(me ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(msg.text,
                style: TextStyle(
                    color: me ? t.colorScheme.onPrimary : t.colorScheme.onSurface)),
            const SizedBox(height: 4),
            Text(DateFormat('h:mm a').format(msg.at),
                style: t.textTheme.labelSmall?.copyWith(
                    color: (me ? t.colorScheme.onPrimary : t.colorScheme.onSurface)
                        .withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: t.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text('Mira is thinking…', style: t.textTheme.bodySmall),
      ),
    );
  }
}

/// Mira suggests remembering something (B4). Nothing is saved unless the
/// user taps Remember.
class _RememberCard extends StatelessWidget {
  const _RememberCard({required this.fact});

  final SuggestedFact fact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Card(
        color: t.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(fact.category.icon, size: 18),
              const SizedBox(width: 6),
              Text('Should I remember this?', style: t.textTheme.labelLarge),
              if (fact.private) ...[
                const SizedBox(width: 6),
                const Icon(Icons.lock_outline, size: 16),
              ],
            ]),
            const SizedBox(height: 6),
            Text('"${fact.text}"', style: t.textTheme.bodyMedium),
            if (fact.private)
              Text('Private: I would only mention that a health note exists.',
                  style: t.textTheme.bodySmall),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => s.dismissSuggestion(fact), child: const Text('No thanks')),
              FilledButton.tonal(onPressed: () => s.confirmFact(fact), child: const Text('Remember')),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Notes about today Mira picked up (C3). Ticked ones are saved on Add;
/// nothing is saved otherwise.
class _AddNotesCard extends StatefulWidget {
  const _AddNotesCard({super.key, required this.notes});

  final List<SuggestedNote> notes;

  @override
  State<_AddNotesCard> createState() => _AddNotesCardState();
}

class _AddNotesCardState extends State<_AddNotesCard> {
  late final Set<SuggestedNote> _ticked = {...widget.notes};

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Card(
        color: t.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('Add to today?', style: t.textTheme.labelLarge),
            ),
            for (final n in widget.notes)
              CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                controlAffinity: ListTileControlAffinity.leading,
                value: _ticked.contains(n),
                onChanged: (v) => setState(() => v == true ? _ticked.add(n) : _ticked.remove(n)),
                title: Text(n.label),
                subtitle: Text(n.type == NoteType.health
                    ? 'Health · private, Mira only knows a note exists'
                    : n.label.toLowerCase().contains('gentle evening')
                        ? 'Plan · pauses limit warnings tonight'
                        : '${n.type.label}${n.forBlock ? ' · this block' : ' · today'}'),
                secondary: Icon(n.type.icon),
              ),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: s.skipNotes, child: const Text('Skip')),
              FilledButton.tonal(
                onPressed: _ticked.isEmpty
                    ? null
                    : () => s.addNotes(widget.notes.where(_ticked.contains).toList()),
                child: const Text('Add'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
