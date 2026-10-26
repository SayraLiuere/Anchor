import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/common.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _name = TextEditingController();
  bool _agreed = false;
  bool _demo = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            const Center(child: MiraAvatar(size: 120)),
            const SizedBox(height: 24),
            Text('Welcome to Anchor',
                textAlign: TextAlign.center,
                style: t.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              "I'm Mira, your little companion. Anchor helps you understand your "
              'screen time and break the cycle of doomscrolling and long gaming '
              "sessions. I'll notice the patterns so you don't have to.",
              textAlign: TextAlign.center,
              style: t.textTheme.bodyLarge,
            ),
            const SizedBox(height: 28),
            ...[
              (Icons.edit_note, 'Log', 'Quick episodes & mood check-ins'),
              (Icons.psychology_alt, 'Predict', 'A Low / Medium / High risk estimate'),
              (Icons.chat, 'Reflect', 'Gentle, personal feedback from Mira'),
            ].map((f) => ListTile(
                  leading: CircleAvatar(
                      backgroundColor: t.colorScheme.primaryContainer,
                      child: Icon(f.$1, color: t.colorScheme.primary)),
                  title: Text(f.$2),
                  subtitle: Text(f.$3),
                )),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'What should I call you? (nickname, optional)',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: t.colorScheme.secondaryContainer.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'Anchor is a self-reflection tool, not a medical device. It does not '
                  'diagnose or treat anything and is not a substitute for professional '
                  'care. Your logs stay on this phone. If an AI key is added, only '
                  'summarised, anonymous numbers and your message text are sent.',
                  style: t.textTheme.bodySmall,
                ),
              ),
            ),
            CheckboxListTile(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              title: const Text('I understand'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: _demo,
              onChanged: (v) => setState(() => _demo = v),
              title: const Text('Fill with demo data'),
              subtitle: const Text('Two weeks of simulated logs, clearly marked'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _agreed
                  ? () {
                      final s = context.read<AppState>();
                      if (_demo) s.seedDemoData();
                      s.completeOnboarding(_name.text);
                    }
                  : null,
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              child: const Text("Let's start"),
            ),
          ],
        ),
      ),
    );
  }
}
