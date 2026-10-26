import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/companion_ai.dart';
import '../services/risk_model.dart';
import '../widgets/common.dart';
import 'screen_time_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppState s = context.read<AppState>();
  late final _name = TextEditingController(text: s.displayName);
  late final _key = TextEditingController(text: s.ai.apiKey);
  late final _model = TextEditingController(text: s.ai.model);
  bool _showKey = false;
  bool _testing = false;
  String? _testResult;

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Continue')),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: 'Nickname', prefixIcon: Icon(Icons.person_outline)),
            onChanged: (v) => s.updateSettings(name: v),
          ),
          const SizedBox(height: 24),
          Card(
            child: ListTile(
              leading: const Icon(Icons.hourglass_bottom),
              title: const Text('Screen time & notifications'),
              subtitle: Text(state.usageGranted
                  ? 'Usage access on · ${state.notificationsGranted ? 'notifications on' : 'notifications off'}'
                  : 'Usage access off'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ScreenTimeScreen())),
            ),
          ),
          const SizedBox(height: 24),
          Text('AI companion (LLM)', style: t.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Add an API key to enable AI replies and weekly recaps. Without a key, '
            'Mira uses built-in template replies. Only anonymous summary numbers and '
            'the text you type are sent.',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          SegmentedButton<LlmProvider>(
            segments: [
              for (final p in LlmProvider.values)
                ButtonSegment(value: p, label: Text(p.label)),
            ],
            selected: {state.ai.provider},
            onSelectionChanged: (v) {
              s.updateSettings(provider: v.first);
              _model.text = s.ai.model;
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: !_showKey,
            decoration: InputDecoration(
              labelText: '${state.ai.provider.label} API key',
              prefixIcon: const Icon(Icons.key),
              suffixIcon: IconButton(
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
            onChanged: (v) => s.updateSettings(apiKey: v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
                labelText: 'Model', prefixIcon: Icon(Icons.memory)),
            onChanged: (v) => s.updateSettings(model: v),
          ),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _testing || !state.ai.online
                  ? null
                  : () async {
                      setState(() => _testing = true);
                      final err = await s.ai.testConnection();
                      if (!mounted) return;
                      setState(() {
                        _testing = false;
                        _testResult = err ?? 'Connected ✓';
                      });
                    },
              icon: _testing
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Test connection'),
            ),
            const SizedBox(width: 12),
            if (_testResult != null)
              Expanded(
                child: Text(_testResult!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(
                        color: _testResult!.startsWith('Connected')
                            ? riskColor(RiskLevel.low)
                            : t.colorScheme.error)),
              ),
          ]),
          const SizedBox(height: 24),
          Text('Your data', style: t.textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.analytics_outlined),
            title: Text('${state.logs.length} entries stored on this phone'),
            subtitle: Text('Risk model: ${state.riskModel.name}'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.copy_all),
            title: const Text('Copy anonymised export (JSON)'),
            subtitle: const Text('For your evaluation analysis. No name or key.'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: state.exportJson()));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Export copied to clipboard')));
            },
          ),
          if (state.syntheticCount == 0)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.science_outlined),
              title: const Text('Add demo data'),
              subtitle: const Text('Two weeks of simulated, marked logs'),
              onTap: state.seedDemoData,
            )
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.science_outlined),
              title: Text('Remove ${state.syntheticCount} demo entries'),
              onTap: state.removeSynthetic,
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_forever, color: t.colorScheme.error),
            title: Text('Erase everything',
                style: TextStyle(color: t.colorScheme.error)),
            onTap: () async {
              if (await _confirm('Erase all data?',
                  'All logs, chats and recaps will be permanently deleted.')) {
                state.clearAll();
              }
            },
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Anchor is a final-year project prototype for self-reflection on '
                'smartphone habits. It is not a medical device and does not '
                'diagnose or treat any condition. If you are struggling, please '
                'reach out to a counsellor or Befrienders KL (03-7627 2929).',
                style: t.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
