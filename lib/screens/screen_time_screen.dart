import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/screen_time.dart';
import '../widgets/common.dart';

/// Opt-in screen time: permission flow, today's apps, the week, and the
/// warning / reminder settings enforced by the background watcher.
class ScreenTimeScreen extends StatelessWidget {
  const ScreenTimeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen time'),
        actions: [
          if (s.usageGranted)
            IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: s.refreshDevice),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          if (!s.usageGranted) const _PermissionCard() else ..._usage(context, s),
          const SectionTitle('Warnings & reminders'),
          const _NudgeSettingsCard(),
        ],
      ),
    );
  }

  List<Widget> _usage(BuildContext context, AppState s) {
    final t = Theme.of(context);
    final u = s.todayUsage;
    if (u == null) return [const Center(child: CircularProgressIndicator())];
    final week = s.weekUsage;
    final maxH = week.fold(1.0, (a, d) => d.totalMinutes / 60 > a ? d.totalMinutes / 60 : a);
    return [
      const SectionTitle('Today'),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.6,
        children: [
          StatTile(label: 'Screen time', value: formatMinutes(u.totalMinutes), icon: Icons.phone_android),
          StatTile(label: 'Unlocks', value: '${u.unlocks}', icon: Icons.lock_open),
          StatTile(
              label: 'Longest session${u.longestSessionApp == null ? '' : ' · ${u.longestSessionApp}'}',
              value: formatMinutes(u.longestSessionMinutes),
              icon: Icons.timelapse),
          StatTile(label: 'After 11pm', value: formatMinutes(u.lateNightMinutes), icon: Icons.bedtime_outlined),
        ],
      ),
      const SectionTitle('Last 7 days'),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final d in week)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text((d.totalMinutes / 60).toStringAsFixed(1), style: t.textTheme.labelSmall),
                        const SizedBox(height: 4),
                        // Social+video share in the darker segment.
                        Container(
                          height: 4 + 96 * (d.totalMinutes / 60) / maxH,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              stops: () {
                                final f = d.totalMinutes == 0
                                    ? 0.0
                                    : ((d.socialMinutes + d.videoMinutes) / d.totalMinutes).clamp(0.0, 1.0);
                                return [f, f];
                              }(),
                              colors: [t.colorScheme.primary, t.colorScheme.primary.withValues(alpha: 0.35)],
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(d.dayStart == null ? '' : DateFormat('E').format(d.dayStart!).substring(0, 2),
                            style: t.textTheme.labelSmall),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6, left: 4),
        child: Text('Darker part = social media + videos (hours)', style: t.textTheme.labelSmall),
      ),
      const SectionTitle('Top apps today'),
      Card(
        child: Column(
          children: [
            if (u.apps.isEmpty) const ListTile(title: Text('No app usage yet today')),
            for (final a in u.apps.take(8))
              ListTile(
                dense: true,
                leading: Icon(_groupIcon(a.group)),
                title: Text(a.label),
                subtitle: Text('${_groupLabel(a.group)} · opened ${a.opens}×'),
                trailing: Text(formatMinutes(a.minutes), style: t.textTheme.labelLarge),
              ),
          ],
        ),
      ),
    ];
  }
}

IconData _groupIcon(String g) => switch (g) {
      'social' => Icons.people_alt_outlined,
      'video' => Icons.smart_display_outlined,
      'games' => Icons.sports_esports_outlined,
      'chat' => Icons.chat_outlined,
      _ => Icons.apps,
    };

String _groupLabel(String g) => switch (g) {
      'social' => 'Social media',
      'video' => 'Video',
      'games' => 'Game',
      'chat' => 'Messaging',
      _ => 'Other',
    };

class _PermissionCard extends StatelessWidget {
  const _PermissionCard();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: MiraAvatar(size: 72, mood: PetMood.excited)),
              const SizedBox(height: 12),
              Text('Can I keep an eye on your screen time?',
                  style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'With "Usage access", Mira can see which apps you use and for how long, '
                'so she can warn you when you have been scrolling or gaming too long.',
              ),
              const SizedBox(height: 12),
              ...[
                (Icons.check_circle_outline, 'Sees: app names, time in each app, unlocks'),
                (Icons.block, 'Never sees: your messages, posts, photos or what you type'),
                (Icons.phone_android, 'Stays on this phone. Only daily totals go into your risk score'),
                (Icons.toggle_off_outlined, 'You can turn it off anytime in the same settings page'),
              ].map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(e.$1, size: 18, color: t.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(e.$2, style: t.textTheme.bodySmall)),
                    ]),
                  )),
              const SizedBox(height: 8),
              Text(
                'Android will open a Settings page. Find "Mira" and switch on "Permit usage access", '
                'then come back here.',
                style: t.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: s.screen.openUsageSettings,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open Usage access settings'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NudgeSettingsCard extends StatelessWidget {
  const _NudgeSettingsCard();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final n = s.nudges;
    final t = Theme.of(context);

    Widget limit(String key, String label, IconData icon, {int max = 240}) {
      final v = n.limits[key] ?? 0;
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(label),
            const Spacer(),
            Text(v == 0 ? 'Off' : formatMinutes(v), style: t.textTheme.labelLarge),
          ]),
          Slider(
            value: v.toDouble().clamp(0, max.toDouble()),
            min: 0,
            max: max.toDouble(),
            divisions: max ~/ 15,
            label: v == 0 ? 'Off' : formatMinutes(v),
            onChanged: n.warningsEnabled
                ? (x) => s.updateNudges((n) => n.limits[key] = x.round())
                : null,
          ),
        ]),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!s.notificationsGranted)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.notifications_off_outlined, color: t.colorScheme.error),
                title: const Text('Notifications are off'),
                subtitle: const Text('Mira needs them to remind and warn you.'),
                trailing: TextButton(
                  onPressed: () async {
                    await s.screen.requestNotificationPermission();
                    await Future.delayed(const Duration(seconds: 2));
                    s.refreshDevice();
                  },
                  child: const Text('Allow'),
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: n.warningsEnabled,
              onChanged: (v) => s.updateNudges((n) => n.warningsEnabled = v),
              title: const Text('Screen-time warnings'),
              subtitle: Text(s.usageGranted
                  ? 'Notify me when I pass a daily limit'
                  : 'Needs screen time access (above)'),
            ),
            limit('social', 'Social media per day', Icons.people_alt_outlined),
            limit('video', 'Videos per day', Icons.smart_display_outlined),
            limit('games', 'Games per day', Icons.sports_esports_outlined),
            limit('total', 'Total screen time per day', Icons.phone_android, max: 720),
            const Divider(height: 24),
            Row(children: [
              const Icon(Icons.waves, size: 18),
              const SizedBox(width: 8),
              const Expanded(child: Text('Doomscroll nudge after one non-stop session of')),
              Text(formatMinutes(n.sessionMinutes), style: t.textTheme.labelLarge),
            ]),
            Slider(
              value: n.sessionMinutes.toDouble(),
              min: 10,
              max: 120,
              divisions: 22,
              label: formatMinutes(n.sessionMinutes),
              onChanged: n.warningsEnabled
                  ? (x) => s.updateNudges((n) => n.sessionMinutes = x.round())
                  : null,
            ),
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: n.logReminder,
              onChanged: (v) => s.updateNudges((n) => n.logReminder = v),
              title: const Text('Daily check-in reminder'),
              subtitle: const Text("Only if you haven't logged anything that day"),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              enabled: n.logReminder,
              leading: const Icon(Icons.schedule),
              title: const Text('Remind me after'),
              trailing: Text(
                  DateFormat('h a').format(DateTime(2000, 1, 1, n.reminderHour)),
                  style: t.textTheme.labelLarge),
              onTap: () async {
                final picked = await showTimePicker(
                    context: context, initialTime: TimeOfDay(hour: n.reminderHour, minute: 0));
                if (picked != null) s.updateNudges((n) => n.reminderHour = picked.hour);
              },
            ),
            Row(children: [
              OutlinedButton.icon(
                onPressed: s.notificationsGranted ? s.screen.testNudge : null,
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Send a test nudge'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: s.screen.checkNow,
                child: const Text('Check now'),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Android checks about every 15 minutes, so warnings can arrive a few minutes late.',
              style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
