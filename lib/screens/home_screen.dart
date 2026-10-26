import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/log_entry.dart';
import '../services/app_state.dart';
import '../services/risk_model.dart';
import '../services/screen_time.dart';
import '../widgets/common.dart';
import 'log_screen.dart';
import 'screen_time_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _petLine;
  final _rnd = Random();

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Still up';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String _companionLine(AppState s) {
    if (_petLine != null) return _petLine!;
    final lastMira = s.chat.lastWhere((m) => !m.fromUser,
        orElse: () => ChatMessage(fromUser: false, text: ''));
    if (lastMira.text.isNotEmpty &&
        DateTime.now().difference(lastMira.at).inHours < 3) {
      return lastMira.text;
    }
    final t = s.todayUsage;
    if (t != null && t.socialMinutes + t.videoMinutes >= 120) {
      return "${formatMinutes(t.socialMinutes + t.videoMinutes)} of scrolling today already… wanna play with me instead? 🐾";
    }
    if (!s.features.hasData) {
      return "Hi hi! I'm Mira. Tell me whenever your phone pulls you in, or turn on screen time so I can keep watch with you.";
    }
    return switch (s.petMood) {
      PetMood.sleepy => "*yawn* It's late… phone on the charger and you in bed?",
      PetMood.worried => "This week's been heavy on the phone. Want to talk about it?",
      PetMood.calm => "I'm noticing a few patterns. A quick check-in could help!",
      PetMood.excited => 'Yay, you came back!',
      PetMood.happy => "You're keeping things balanced. I'm proud of you!",
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final t = Theme.of(context);
    final today = s.logs.where((l) {
      final n = DateTime.now();
      return l.kind == EntryKind.episode &&
          l.timestamp.year == n.year &&
          l.timestamp.month == n.month &&
          l.timestamp.day == n.day;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
            '${_greeting()}${s.displayName.isEmpty ? '' : ', ${s.displayName}'}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openLogSheet(context, EntryKind.episode),
        icon: const Icon(Icons.add),
        label: const Text('Log episode'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
        children: [
          // Pet hero
          Column(children: [
            MiraPet(
              mood: s.petMood,
              size: 110,
              onPet: () {
                final lines = petLines[s.petMood]!;
                final line = lines[_rnd.nextInt(lines.length)];
                setState(() => _petLine = line);
                Future.delayed(const Duration(seconds: 6), () {
                  if (mounted && _petLine == line) setState(() => _petLine = null);
                });
              },
            ),
            _SpeechBubble(
              text: _companionLine(s),
              onTap: () => RootShell.goTo(context, 1),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ...List.generate(
                  5,
                  (i) => Icon(
                        i < (s.bondDays / 4).ceil().clamp(0, 5)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        size: 16,
                        color: t.colorScheme.primary,
                      )),
              const SizedBox(width: 8),
              Text('Bond: ${s.bondDays} day${s.bondDays == 1 ? '' : 's'} this month',
                  style: t.textTheme.labelSmall),
            ]),
          ]),
          const SizedBox(height: 16),
          if (s.drafts.isNotEmpty) ...[
            DraftsCard(state: s),
            const SizedBox(height: 14),
          ],
          ScreenTimeCard(state: s),
          const SizedBox(height: 14),
          RiskCard(risk: s.risk),
          const SectionTitle('Quick actions'),
          Row(children: [
            Expanded(
                child: _ActionButton(
                    icon: Icons.phone_android,
                    label: 'Episode',
                    onTap: () => openLogSheet(context, EntryKind.episode))),
            const SizedBox(width: 10),
            Expanded(
                child: _ActionButton(
                    icon: Icons.favorite_outline,
                    label: 'Check-in',
                    onTap: () => openLogSheet(context, EntryKind.checkIn))),
            const SizedBox(width: 10),
            Expanded(
                child: _ActionButton(
                    icon: Icons.chat_bubble_outline,
                    label: 'Vent',
                    onTap: () => RootShell.goTo(context, 1))),
          ]),
          const SectionTitle('Logged today'),
          Row(children: [
            Expanded(
                child: StatTile(
                    label: 'Episodes',
                    value: '${today.length}',
                    icon: Icons.phone_android)),
            const SizedBox(width: 10),
            Expanded(
                child: StatTile(
                    label: 'Urges resisted',
                    value: '${today.where((e) => e.resisted).length}',
                    icon: Icons.shield_outlined)),
            const SizedBox(width: 10),
            Expanded(
                child: StatTile(
                    label: 'Minutes',
                    value:
                        '${today.where((e) => !e.resisted).fold(0, (a, e) => a + e.durationMinutes)}',
                    icon: Icons.timer_outlined)),
          ]),
          if (s.weeklySummary != null) ...[
            const SectionTitle('Your latest weekly recap'),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => RootShell.goTo(context, 3),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(s.weeklySummary!,
                      maxLines: 4, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: Container(
          key: ValueKey(text),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: t.colorScheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(text,
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyMedium),
        ),
      ),
    );
  }
}

/// Today's measured screen time against the user's limits, or an invitation
/// to turn it on.
class ScreenTimeCard extends StatelessWidget {
  const ScreenTimeCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    void open() => Navigator.push(
        context, MaterialPageRoute(builder: (_) => const ScreenTimeScreen()));

    final u = state.todayUsage;
    if (!state.usageGranted || u == null) {
      return Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: Icon(Icons.hourglass_bottom, color: t.colorScheme.primary),
          title: const Text('Let Mira see your screen time'),
          subtitle: const Text(
              'Optional. Unlocks automatic tracking and warnings when you scroll too long.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: open,
        ),
      );
    }

    final limits = state.nudges.limits;
    final rows = [
      ('Social media', u.socialMinutes, limits['social'] ?? 0, Icons.people_alt_outlined),
      ('Videos', u.videoMinutes, limits['video'] ?? 0, Icons.smart_display_outlined),
      ('Games', u.gamesMinutes, limits['games'] ?? 0, Icons.sports_esports_outlined),
    ];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('Screen time today',
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(formatMinutes(u.totalMinutes),
                    style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ]),
              Text('${u.unlocks} unlocks', style: t.textTheme.labelSmall),
              const SizedBox(height: 12),
              for (final (label, mins, limit, icon) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    SizedBox(width: 92, child: Text(label, style: t.textTheme.bodySmall)),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: limit == 0 ? 0 : (mins / limit).clamp(0.0, 1.0),
                          minHeight: 8,
                          color: limit > 0 && mins >= limit
                              ? riskColor(RiskLevel.high)
                              : limit > 0 && mins >= limit * 0.75
                                  ? riskColor(RiskLevel.medium)
                                  : riskColor(RiskLevel.low),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 78,
                      child: Text(
                        limit == 0
                            ? formatMinutes(mins)
                            : '${formatMinutes(mins)}/${formatMinutes(limit)}',
                        textAlign: TextAlign.end,
                        style: t.textTheme.labelSmall,
                      ),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(children: [
            Icon(icon, color: t.colorScheme.primary),
            const SizedBox(height: 6),
            Text(label, style: t.textTheme.labelLarge),
          ]),
        ),
      ),
    );
  }
}

/// Risk indicator with gauge + top contributing factors (FR4, FR7).
class RiskCard extends StatelessWidget {
  const RiskCard({super.key, required this.risk});

  final RiskResult risk;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = riskColor(risk.level);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: risk.score.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 700),
                builder: (_, v, __) => CustomPaint(
                  painter: _GaugePainter(v, color,
                      t.colorScheme.surfaceContainerHighest),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(risk.level.label,
                            style: t.textTheme.titleMedium?.copyWith(
                                color: color, fontWeight: FontWeight.w800)),
                        Text('risk', style: t.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PSU risk this week',
                      style: t.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  if (risk.reasons.isEmpty)
                    Text('No strong warning signs this week',
                        style: t.textTheme.bodySmall),
                  ...risk.reasons.map((r) => Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 6),
                              child: CircleAvatar(radius: 3, backgroundColor: color),
                            ),
                            Expanded(
                                child: Text(r, style: t.textTheme.bodySmall)),
                          ],
                        ),
                      )),
                  const SizedBox(height: 4),
                  Text(risk.modelName,
                      style: t.textTheme.labelSmall
                          ?.copyWith(color: t.colorScheme.outline)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.value, this.color, this.track);

  final double value;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const start = pi * 0.75, sweep = pi * 1.5;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(6), start, sweep, false, p..color = track);
    canvas.drawArc(rect.deflate(6), start, sweep * max(value, 0.02), false,
        p..color = color);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.color != color;
}

/// Long sessions Mira noticed, each waiting for a one-tap reason or a skip.
class DraftsCard extends StatelessWidget {
  const DraftsCard({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final drafts = state.drafts;
    final shown = drafts.take(3).toList();
    return Card(
      color: t.colorScheme.tertiaryContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              drafts.length == 1
                  ? 'Mira noticed a long session'
                  : 'Mira noticed ${drafts.length} long sessions',
              style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text('What pulled you in? Tap one to tell her.', style: t.textTheme.bodySmall),
            const SizedBox(height: 6),
            for (final d in shown)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(groupIcon(d.group)),
                title: Text('${formatMinutes(d.minutes)} on ${d.label}'),
                subtitle: Text(_when(d.start)),
                onTap: () => openLogSheet(context, EntryKind.episode, draft: d),
                trailing: IconButton(
                  tooltip: 'Not a problem, skip',
                  icon: const Icon(Icons.close),
                  onPressed: () => state.dismissDraft(d.id),
                ),
              ),
            if (drafts.length > shown.length)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('+ ${drafts.length - shown.length} more',
                    style: t.textTheme.labelSmall),
              ),
          ],
        ),
      ),
    );
  }

  static String _when(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final time = DateFormat('h:mm a').format(d);
    if (day == today) return 'Today, $time';
    if (today.difference(day).inDays == 1) return 'Yesterday, $time';
    return DateFormat('EEE, h:mm a').format(d);
  }
}
