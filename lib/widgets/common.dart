import 'package:flutter/material.dart';

import '../services/risk_model.dart';

export 'mira_pet.dart';

Color riskColor(RiskLevel l) => switch (l) {
      RiskLevel.low => const Color(0xFF2EAD7A),
      RiskLevel.medium => const Color(0xFFF2A33A),
      RiskLevel.high => const Color(0xFFE5566B),
    };

/// 1–5 scale picker with emoji anchors.
class ScalePicker extends StatelessWidget {
  const ScalePicker({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.faces,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final List<String> faces;

  static const moodFaces = ['😞', '🙁', '😐', '🙂', '😄'];
  static const stressFaces = ['😌', '🙂', '😐', '😣', '😫'];
  static const urgeFaces = ['🧘', '🙂', '🤔', '📱', '🔥'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: List.generate(5, (i) {
            final selected = value == i + 1;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onChanged(i + 1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: selected ? scheme.primary : Colors.transparent,
                          width: 2),
                    ),
                    child: Column(children: [
                      Text(faces[i], style: const TextStyle(fontSize: 22)),
                      Text('${i + 1}',
                          style: Theme.of(context).textTheme.labelSmall),
                    ]),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile(
      {super.key, required this.label, required this.value, required this.icon});

  final String label, value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: t.colorScheme.primary),
            const SizedBox(height: 8),
            Text(value,
                style: t.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: t.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
