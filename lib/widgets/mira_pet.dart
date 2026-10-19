import 'dart:math';

import 'package:flutter/material.dart';

import '../services/app_state.dart';

/// Mira's face: a round little creature with ears whose expression follows
/// her [PetMood].
class MiraAvatar extends StatelessWidget {
  const MiraAvatar({super.key, this.size = 48, this.mood = PetMood.happy});

  final double size;
  final PetMood mood;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MiraPainter(scheme.primary, scheme.primaryContainer, mood),
      ),
    );
  }
}

class _MiraPainter extends CustomPainter {
  _MiraPainter(this.fg, this.bg, this.mood);

  final Color fg, bg;
  final PetMood mood;

  static const ink = Color(0xFF2D2A4A);

  @override
  void paint(Canvas canvas, Size s) {
    final r = s.width * 0.42;
    final c = Offset(s.width / 2, s.height * 0.56);
    final body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.4),
        colors: [Color.lerp(bg, Colors.white, 0.3)!, fg.withValues(alpha: 0.75)],
      ).createShader(Rect.fromCircle(center: c, radius: r * 1.3));

    // Ears
    for (final side in [-1.0, 1.0]) {
      final ear = Path()
        ..moveTo(c.dx + side * r * 0.35, c.dy - r * 0.75)
        ..quadraticBezierTo(c.dx + side * r * 0.95, c.dy - r * 1.45,
            c.dx + side * r * 0.95, c.dy - r * 0.45)
        ..close();
      canvas.drawPath(ear, body);
      final inner = Path()
        ..moveTo(c.dx + side * r * 0.5, c.dy - r * 0.72)
        ..quadraticBezierTo(c.dx + side * r * 0.85, c.dy - r * 1.18,
            c.dx + side * r * 0.85, c.dy - r * 0.6)
        ..close();
      canvas.drawPath(inner, Paint()..color = const Color(0xFFFFB3C7).withValues(alpha: 0.8));
    }

    canvas.drawOval(Rect.fromCenter(center: c, width: r * 2.1, height: r * 1.9), body);

    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.5, r * 0.09)
      ..strokeCap = StrokeCap.round;
    final eyeY = c.dy - r * 0.08;
    final eyes = [Offset(c.dx - r * 0.38, eyeY), Offset(c.dx + r * 0.38, eyeY)];

    // Cheeks
    if (mood == PetMood.happy || mood == PetMood.excited) {
      final blush = Paint()..color = const Color(0xFFFF8FAB).withValues(alpha: 0.45);
      for (final e in eyes) {
        canvas.drawOval(
            Rect.fromCenter(
                center: e + Offset((e.dx < c.dx ? -1 : 1) * r * 0.12, r * 0.32),
                width: r * 0.32,
                height: r * 0.18),
            blush);
      }
    }

    // Eyes
    switch (mood) {
      case PetMood.excited:
        for (final e in eyes) {
          canvas.drawArc(Rect.fromCircle(center: e + Offset(0, r * 0.06), radius: r * 0.13),
              pi + 0.3, pi - 0.6, false, stroke);
        }
      case PetMood.sleepy:
        for (final e in eyes) {
          canvas.drawArc(Rect.fromCircle(center: e - Offset(0, r * 0.06), radius: r * 0.13),
              0.3, pi - 0.6, false, stroke);
        }
      default:
        for (final e in eyes) {
          canvas.drawCircle(e, r * 0.17, Paint()..color = Colors.white);
          canvas.drawCircle(e + Offset(0, r * 0.03), r * 0.11, Paint()..color = ink);
          canvas.drawCircle(e + Offset(r * 0.04, -r * 0.02), r * 0.035,
              Paint()..color = Colors.white);
        }
        if (mood == PetMood.worried) {
          for (final e in eyes) {
            final dir = e.dx < c.dx ? 1 : -1;
            canvas.drawLine(e + Offset(-dir * r * 0.15, -r * 0.3),
                e + Offset(dir * r * 0.12, -r * 0.22), stroke);
          }
        }
    }

    // Mouth
    final m = c + Offset(0, r * 0.38);
    switch (mood) {
      case PetMood.happy:
        canvas.drawArc(Rect.fromCenter(center: m - Offset(0, r * 0.1), width: r * 0.45, height: r * 0.3),
            0.2, pi - 0.4, false, stroke);
      case PetMood.excited:
        final mouth = Path()
          ..moveTo(m.dx - r * 0.25, m.dy - r * 0.08)
          ..quadraticBezierTo(m.dx, m.dy + r * 0.4, m.dx + r * 0.25, m.dy - r * 0.08)
          ..close();
        canvas.drawPath(mouth, Paint()..color = ink);
      case PetMood.calm:
        canvas.drawArc(Rect.fromCenter(center: m - Offset(0, r * 0.05), width: r * 0.3, height: r * 0.15),
            0.3, pi - 0.6, false, stroke);
      case PetMood.worried:
        canvas.drawArc(Rect.fromCenter(center: m + Offset(0, r * 0.08), width: r * 0.4, height: r * 0.25),
            pi + 0.35, pi - 0.7, false, stroke);
      case PetMood.sleepy:
        canvas.drawOval(Rect.fromCenter(center: m, width: r * 0.14, height: r * 0.18), stroke);
        final tp = TextPainter(
          text: TextSpan(
              text: 'z',
              style: TextStyle(color: ink, fontSize: r * 0.45, fontWeight: FontWeight.w700)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(c.dx + r * 0.75, c.dy - r * 1.2));
    }
  }

  @override
  bool shouldRepaint(covariant _MiraPainter old) => old.mood != mood || old.fg != fg;
}

/// Interactive Mira: gently "breathes" while idle and bounces with a heart
/// when tapped.
class MiraPet extends StatefulWidget {
  const MiraPet({super.key, required this.mood, this.size = 120, this.onPet});

  final PetMood mood;
  final double size;
  final VoidCallback? onPet;

  @override
  State<MiraPet> createState() => _MiraPetState();
}

class _MiraPetState extends State<MiraPet> with TickerProviderStateMixin {
  late final _breath = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat(reverse: true);
  late final _bounce =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void dispose() {
    _breath.dispose();
    _bounce.dispose();
    super.dispose();
  }

  void _tap() {
    _bounce.forward(from: 0);
    widget.onPet?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _tap,
      child: AnimatedBuilder(
        animation: Listenable.merge([_breath, _bounce]),
        builder: (_, __) {
          final breathe = 1 + 0.035 * Curves.easeInOut.transform(_breath.value);
          final b = _bounce.value;
          final hop = b == 0 ? 0.0 : sin(b * pi) * widget.size * 0.12;
          return SizedBox(
            width: widget.size * 1.3,
            height: widget.size * 1.3,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Transform.translate(
                  offset: Offset(0, -hop),
                  child: Transform.scale(
                    scaleY: breathe,
                    scaleX: 2 - breathe,
                    child: MiraAvatar(
                        size: widget.size,
                        mood: b > 0 && b < 1 ? PetMood.excited : widget.mood),
                  ),
                ),
                if (b > 0 && b < 1)
                  Positioned(
                    top: widget.size * (0.15 - 0.15 * b),
                    right: widget.size * 0.12,
                    child: Opacity(
                      opacity: 1 - b,
                      child: Text('💜', style: TextStyle(fontSize: widget.size * 0.2)),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Things Mira says when you pet her, by mood.
const petLines = {
  PetMood.happy: [
    'Hehe, that tickles!',
    "I like hanging out with you when your phone's resting too.",
    "You're doing great this week, I can feel it.",
  ],
  PetMood.calm: [
    'Mm, scritches are nice.',
    "I'm here if you want to talk about anything.",
    "Let's keep an eye on those sneaky scrolling moments together.",
  ],
  PetMood.excited: [
    "Again! Again!",
    'Ooh, I love when you visit me!',
  ],
  PetMood.worried: [
    "I've been a little worried about you this week.",
    'Maybe we could take a tiny break together?',
    'Pets make everything better. Phones… not always.',
  ],
  PetMood.sleepy: [
    "*yawn* It's so late… should we both go to sleep?",
    "My eyes are closing… yours should too 😴",
    'Sleepy Mira says: phone on the charger, you under the blanket.',
  ],
};
