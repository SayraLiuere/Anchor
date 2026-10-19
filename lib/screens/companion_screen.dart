import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../services/app_state.dart';
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
            Text(s.ai.online ? 'AI companion · ${s.ai.model}' : 'Offline mode',
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
