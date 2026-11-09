import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Motion language. Timings follow common guidance: feedback ≈150 ms,
/// small elements ≈250 ms, page changes ≈320 ms, nothing over 500 ms.
class Motion {
  static const fast = Duration(milliseconds: 150);
  static const base = Duration(milliseconds: 250);
  static const page = Duration(milliseconds: 320);
  static const slow = Duration(milliseconds: 460);
  static const ease = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  static bool reduced(BuildContext c) => MediaQuery.maybeDisableAnimationsOf(c) ?? false;
}

/// One color per launch: picked when the app opens, used by the mark,
/// the opening animation and (on Windows) the window and tray icon.
class Launch {
  static final int colorIndex = Random().nextInt(6);
  static Color color(BuildContext c) => c.ink.tags[colorIndex];
}

/// Press feedback for anything tappable: 3% scale-down, soft hover tint,
/// a light haptic tick on the phone.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final BorderRadius radius;
  final Color? hoverColor;
  final double pressedScale;
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.radius = const BorderRadius.all(Radius.circular(6)),
    this.hoverColor,
    this.pressedScale = .97,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final c = context.ink;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap == null
            ? null
            : () {
                if (Platform.isAndroid) HapticFeedback.selectionClick();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                if (Platform.isAndroid) HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        onSecondaryTap: widget.onSecondaryTap,
        child: AnimatedScale(
          scale: _down ? widget.pressedScale : 1,
          duration: Motion.fast,
          curve: Motion.ease,
          child: AnimatedContainer(
            duration: Motion.fast,
            decoration: BoxDecoration(
              borderRadius: widget.radius,
              color: enabled && (_hover || _down) ? (widget.hoverColor ?? c.sheet) : Colors.transparent,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Fades and lifts a child into place, optionally after [delay].
class Entrance extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final double dy;
  final Duration duration;
  const Entrance(
      {super.key, required this.child, this.delay = Duration.zero, this.dy = 10, this.duration = Motion.slow});
  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: widget.duration);

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _a.forward();
    });
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return widget.child;
    final t = CurvedAnimation(parent: _a, curve: Motion.emphasized);
    return AnimatedBuilder(
      animation: t,
      builder: (_, child) => Opacity(
        opacity: t.value,
        child: Transform.translate(offset: Offset(0, widget.dy * (1 - t.value)), child: child),
      ),
      child: widget.child,
    );
  }
}

/// A small status dot; when [live], a soft ring breathes out of it.
class BreathingDot extends StatefulWidget {
  final bool live;
  final Color color;
  final Color idle;
  const BreathingDot({super.key, required this.live, required this.color, required this.idle});
  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    if (widget.live) _a.repeat();
  }

  @override
  void didUpdateWidget(BreathingDot old) {
    super.didUpdateWidget(old);
    if (widget.live && !_a.isAnimating) _a.repeat();
    if (!widget.live) _a.stop();
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _a,
        builder: (_, __) {
          final t = Curves.easeOut.transform(_a.value);
          return Stack(alignment: Alignment.center, children: [
            if (widget.live && !Motion.reduced(context))
              Container(
                width: 6 + 8 * t,
                height: 6 + 8 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: .35 * (1 - t)),
                ),
              ),
            AnimatedContainer(
              duration: Motion.base,
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.live ? widget.color : null,
                border: widget.live ? null : Border.all(color: widget.idle, width: 1),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

/// Faint, still dot-grid "graph paper" for empty space only (never behind
/// text). No moving light: the old sweeping band read as a box drifting
/// behind the page.
class PaperBackground extends StatelessWidget {
  final Widget child;
  const PaperBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return CustomPaint(
      painter: _GridPainter(dot: c.rule, dark: Theme.of(context).brightness == Brightness.dark),
      child: child,
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color dot;
  final bool dark;
  _GridPainter({required this.dot, required this.dark});

  @override
  void paint(Canvas canvas, Size s) {
    const step = 22.0;
    final p = Paint()..color = dot.withValues(alpha: dark ? .55 : .7);
    // Anchored to the centre so the grid looks the same at any window size.
    final ox = (s.width / 2) % step, oy = (s.height / 2) % step;
    for (var y = oy; y < s.height; y += step) {
      for (var x = ox; x < s.width; x += step) {
        canvas.drawCircle(Offset(x, y), 0.9, p);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => o.dot != dot || o.dark != dark;
}

/// Page change: the new page slides in a little and fades up; the old one
/// recedes slightly. Used on both Android and Windows.
class SlideFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const SlideFadePageTransitionsBuilder();
  @override
  Duration get transitionDuration => Motion.page;
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondary, Widget child) {
    // Only the incoming page moves: it slides in a little and fades up over
    // the old page, which stays perfectly still (no scaling, so no visible
    // page edges or box outlines during the change).
    final inT = CurvedAnimation(parent: animation, curve: Motion.emphasized, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: inT,
      child: SlideTransition(
        position: Tween(begin: const Offset(.06, 0), end: Offset.zero).animate(inT),
        child: ColoredBox(color: context.ink.paper, child: child),
      ),
    );
  }
}

/// Opening animation: the four tiles of the mark drop in one after another
/// in today's color, the wordmark slides in, then everything fades away.
class LaunchIntro extends StatefulWidget {
  final Widget child;
  const LaunchIntro({super.key, required this.child});
  @override
  State<LaunchIntro> createState() => _LaunchIntroState();
}

class _LaunchIntroState extends State<LaunchIntro> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _a.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone || Motion.reduced(context)) return widget.child;
    final c = context.ink;
    final col = Launch.color(context);
    return Stack(children: [
      widget.child,
      AnimatedBuilder(
        animation: _a,
        builder: (_, __) {
          final v = _a.value;
          final fadeOut = v < .72 ? 1.0 : 1 - Curves.easeIn.transform((v - .72) / .28);
          return IgnorePointer(
            ignoring: v > .72,
            child: Opacity(
              opacity: fadeOut,
              child: Container(
                color: c.paper,
                alignment: Alignment.center,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: CustomPaint(painter: _IntroTiles(v, col)),
                  ),
                  const SizedBox(width: 14),
                  Opacity(
                    opacity: Curves.easeOut.transform(((v - .3) / .3).clamp(0, 1)),
                    child: Transform.translate(
                      offset: Offset(-12 * (1 - ((v - .3) / .3).clamp(0.0, 1.0)), 0),
                      child: Text('H11', style: T.title(c, size: 34).copyWith(letterSpacing: -.5)),
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    ]);
  }
}

class _IntroTiles extends CustomPainter {
  final double v;
  final Color col;
  _IntroTiles(this.v, this.col);
  @override
  void paint(Canvas canvas, Size s) {
    final g = s.width * .12;
    final t = (s.width - g) / 2;
    for (var i = 0; i < 4; i++) {
      final start = i * .08;
      final k = Motion.emphasized.transform(((v - start) / .28).clamp(0.0, 1.0));
      if (k <= 0) continue;
      final x = (i % 2) * (t + g), y = (i ~/ 2) * (t + g);
      final r = Rect.fromLTWH(x, y - 10 * (1 - k), t, t);
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(t * .22)),
          Paint()..color = col.withValues(alpha: k));
    }
  }

  @override
  bool shouldRepaint(_IntroTiles o) => o.v != v || o.col != col;
}
