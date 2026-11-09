import 'package:flutter/material.dart';

import 'motion.dart';

/// H11 design language: crisp, colorful, professional.
/// Cool white and deep navy ink, cobalt for actions, a six-color system
/// that gives every page its own color, green that means "linked".
/// Flat surfaces, hairline rules, small radii, one sans family.
class Palette extends ThemeExtension<Palette> {
  final Color paper; // page background
  final Color sheet; // raised surfaces (inputs, dialogs, selected rows)
  final Color ink; // primary text
  final Color pencil; // secondary text
  final Color faint; // tertiary text, placeholders
  final Color rule; // hairlines
  final Color accent; // cobalt: actions and focus
  final Color onAccent;
  final Color linked; // green: connection is up
  final Color danger;
  final Color selection;
  final List<Color> tags; // per-page colors

  const Palette({
    required this.paper,
    required this.sheet,
    required this.ink,
    required this.pencil,
    required this.faint,
    required this.rule,
    required this.accent,
    required this.onAccent,
    required this.linked,
    required this.danger,
    required this.selection,
    required this.tags,
  });

  static const light = Palette(
    paper: Color(0xFFFBFBFD),
    sheet: Color(0xFFF1F3F8),
    ink: Color(0xFF0F1A2E),
    pencil: Color(0xFF4A5568),
    faint: Color(0xFF8A94A6),
    rule: Color(0xFFE2E6EE),
    accent: Color(0xFF2450E6),
    onAccent: Color(0xFFFFFFFF),
    linked: Color(0xFF0F9D6B),
    danger: Color(0xFFD02F5A),
    selection: Color(0x332450E6),
    tags: [
      Color(0xFF2450E6), // cobalt
      Color(0xFF0F9D6B), // emerald
      Color(0xFFE3A008), // saffron
      Color(0xFFD02F5A), // magenta-rose
      Color(0xFF0B9CD8), // sky
      Color(0xFF13A3A0), // teal
    ],
  );

  static const dark = Palette(
    paper: Color(0xFF0D1220),
    sheet: Color(0xFF151C2E),
    ink: Color(0xFFE9EDF5),
    pencil: Color(0xFFA7B1C4),
    faint: Color(0xFF66718A),
    rule: Color(0xFF232C42),
    accent: Color(0xFF5B80FF),
    onAccent: Color(0xFFFFFFFF),
    linked: Color(0xFF34D399),
    danger: Color(0xFFFF6B8F),
    selection: Color(0x445B80FF),
    tags: [
      Color(0xFF5B80FF),
      Color(0xFF34D399),
      Color(0xFFFBBF24),
      Color(0xFFFF6B8F),
      Color(0xFF38BDF8),
      Color(0xFF2DD4BF),
    ],
  );

  /// Stable color for a page, derived from its id.
  Color tagFor(String id) {
    var h = 0;
    for (final u in id.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return tags[h % tags.length];
  }

  @override
  Palette copyWith() => this;
  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) =>
      t < .5 ? this : (other as Palette? ?? this);
}

const sans = 'PlexArabic'; // IBM Plex Sans Arabic carries full Latin too
const serif = sans; // one family throughout
const mono = 'PlexMono';
const fallback = [sans];

extension InkOf on BuildContext {
  Palette get ink => Theme.of(this).extension<Palette>()!;
}

class T {
  static TextStyle label(Palette c) => TextStyle(
      fontFamily: sans, fontSize: 11, fontWeight: FontWeight.w700,
      letterSpacing: 1.3, color: c.pencil, height: 1.2);
  static TextStyle meta(Palette c) => TextStyle(
      fontFamily: mono, fontSize: 11.5, color: c.faint, height: 1.3,
      fontFamilyFallback: fallback);
  static TextStyle ui(Palette c, {double size = 14, FontWeight w = FontWeight.w400, Color? color}) =>
      TextStyle(fontFamily: sans, fontSize: size, fontWeight: w, color: color ?? c.ink, height: 1.35);
  static TextStyle title(Palette c, {double size = 26}) => TextStyle(
      fontFamily: sans, fontSize: size, fontWeight: FontWeight.w700, color: c.ink,
      height: 1.25, letterSpacing: -0.4);
  static TextStyle body(Palette c) => TextStyle(
      fontFamily: sans, fontSize: 16.5, color: c.ink, height: 1.7);
  static TextStyle rowTitle(Palette c) => TextStyle(
      fontFamily: sans, fontSize: 15.5, fontWeight: FontWeight.w600, color: c.ink,
      height: 1.3, letterSpacing: -0.1);
}

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.light ? Palette.light : Palette.dark;
  return ThemeData(
    brightness: b,
    useMaterial3: true,
    fontFamily: sans,
    scaffoldBackgroundColor: c.paper,
    colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      secondary: c.linked,
      surface: c.paper,
      onSurface: c.ink,
      outline: c.rule,
      error: c.danger,
    ),
    extensions: [c],
    splashFactory: NoSplash.splashFactory,
    highlightColor: c.rule.withValues(alpha: .5),
    hoverColor: c.sheet,
    dividerTheme: DividerThemeData(color: c.rule, thickness: 1, space: 1),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.selection,
      selectionHandleColor: c.accent,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: InputBorder.none,
      isDense: true,
      contentPadding: EdgeInsets.zero,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: T.ui(c, color: c.paper, size: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(4)),
      textStyle: T.ui(c, color: c.paper, size: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: SlideFadePageTransitionsBuilder(),
      TargetPlatform.windows: SlideFadePageTransitionsBuilder(),
    }),
  );
}

/// A quiet text button. [accent] makes it cobalt.
class InkButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool strong;
  final bool accent;
  final bool danger;
  final Widget? lead;
  const InkButton(this.label,
      {super.key, this.onTap, this.strong = false, this.accent = false, this.danger = false, this.lead});

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final color = onTap == null ? c.faint : (danger ? c.danger : accent ? c.accent : c.ink);
    // A barely-there outline so every tappable thing reads as a button.
    final edge = onTap == null
        ? c.rule.withValues(alpha: .5)
        : (danger || accent) ? color.withValues(alpha: .28) : c.rule;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Pressable(
        onTap: onTap,
        hoverColor: (danger || accent) ? color.withValues(alpha: .07) : c.sheet,
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: edge, width: 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (lead != null) ...[lead!, if (label.isNotEmpty) const SizedBox(width: 6)],
            if (label.isNotEmpty)
            AnimatedDefaultTextStyle(
              duration: Motion.fast,
              style: T.ui(c, size: 13.5, w: strong ? FontWeight.w700 : FontWeight.w500, color: color),
              child: Text(label),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The primary button: solid cobalt.
class BlockButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const BlockButton(this.label, {super.key, this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Pressable(
      onTap: onTap,
      hoverColor: Colors.transparent,
      child: AnimatedContainer(
        duration: Motion.base,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: onTap == null ? c.rule : c.accent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: onTap == null
              ? null
              : [BoxShadow(color: c.accent.withValues(alpha: .25), blurRadius: 10, offset: const Offset(0, 3))],
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: T.ui(c, size: 14, w: FontWeight.w600, color: c.onAccent)),
      ),
    );
  }
}

/// Small "New page" pill: cobalt fill, the one loud element in the header.
class AccentChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const AccentChip(this.label, {super.key, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Pressable(
        onTap: onTap,
        hoverColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [BoxShadow(color: c.accent.withValues(alpha: .25), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Text(label, style: T.ui(c, size: 13, w: FontWeight.w600, color: c.onAccent)),
        ),
      ),
    );
  }
}

class Hairline extends StatelessWidget {
  final double indent;
  const Hairline({super.key, this.indent = 0});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsetsDirectional.only(start: indent),
        child: Container(height: 1, color: context.ink.rule),
      );
}

/// The H11 mark: four tiles in a 2×2 grid, all in the color picked for
/// this launch. When [dimRight] is set, the tiles turn grey.
class Mark extends StatelessWidget {
  final double size;
  final bool dimRight;
  const Mark({super.key, this.size = 18, this.dimRight = false});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter(context.ink, dimRight, Launch.color(context)));
}

class _MarkPainter extends CustomPainter {
  final Palette c;
  final bool dim;
  final Color tone;
  _MarkPainter(this.c, this.dim, this.tone);
  @override
  void paint(Canvas canvas, Size s) {
    final g = s.width * .12;
    final t = (s.width - g) / 2;
    for (var i = 0; i < 4; i++) {
      final x = (i % 2) * (t + g), y = (i ~/ 2) * (t + g);
      final p = Paint()..color = dim ? c.faint.withValues(alpha: .55) : tone;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, y, t, t), Radius.circular(t * .22)), p);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter o) => o.c != c || o.dim != dim || o.tone != tone;
}
