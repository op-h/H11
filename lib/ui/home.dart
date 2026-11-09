import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/model.dart';
import '../core/sync.dart';
import 'controller.dart';
import 'link_screen.dart';
import 'motion.dart';
import 'page.dart';
import 'settings.dart';
import 'theme.dart';

const _months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

String shortDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1]}';
}

String fullDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final m = _months[d.month - 1];
  return '${d.day.toString().padLeft(2, '0')} ${m[0]}${m.substring(1).toLowerCase()} ${d.year}, '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class Home extends StatefulWidget {
  final AppController app;
  final Widget? desktopBar;
  const Home({super.key, required this.app, this.desktopBar});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  String? _openId;
  String _query = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  StreamSubscription? _toastSub;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_onChange);
    _toastSub = app.toasts.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Phone came back to the foreground: reconnect immediately.
    if (s == AppLifecycleState.resumed && app.engine is ClientEngine) {
      (app.engine as ClientEngine).poke();
    }
  }

  void _onChange() {
    if (_openId != null && app.store.get(_openId!) == null) _openId = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_onChange);
    _toastSub?.cancel();
    super.dispose();
  }

  bool _wide(BuildContext c) => MediaQuery.sizeOf(c).width >= 760;

  Future<void> _new() async {
    final s = await app.newSession();
    _open(s.id, focusBody: true);
  }

  void _open(String id, {bool focusBody = false}) {
    if (_wide(context)) {
      setState(() => _openId = id);
    } else {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PageScreen(app: app, id: id, autofocus: focusBody, standalone: true)));
    }
  }

  List<Session> _items() {
    final all = app.store.sorted();
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((s) =>
            s.title.toLowerCase().contains(q) ||
            s.body.toLowerCase().contains(q) ||
            s.attachments.any((a) => a.name.toLowerCase().contains(q)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final wide = _wide(context);
    final list = _IndexColumn(
      app: app,
      items: _items(),
      selected: wide ? _openId : null,
      onOpen: _open,
      search: _search,
      searchFocus: _searchFocus,
      onQuery: (q) => setState(() => _query = q),
      empty: app.store.sessions.isEmpty,
      onNew: _new,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _new,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _searchFocus.requestFocus(),
      },
      child: Scaffold(
        backgroundColor: c.paper,
        body: ColoredBox(
          color: c.paper,
          child: SafeArea(
          child: Column(children: [
            _Header(app: app, onNew: _new, desktopBar: widget.desktopBar),
            _StatusLine(app: app),
            Hairline(),
            Expanded(
              child: wide
                  ? Row(children: [
                      SizedBox(width: 330, child: list),
                      Container(width: 1, color: c.rule),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Motion.page,
                          switchInCurve: Motion.emphasized,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, a) => FadeTransition(
                            opacity: a,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0, .015), end: Offset.zero).animate(a),
                              child: child,
                            ),
                          ),
                          child: _openId == null
                              ? const _Blank()
                              : PageScreen(key: ValueKey(_openId), app: app, id: _openId!),
                        ),
                      ),
                    ])
                  : list,
            ),
          ]),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AppController app;
  final VoidCallback onNew;
  final Widget? desktopBar;
  const _Header({required this.app, required this.onNew, this.desktopBar});

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final narrow = MediaQuery.sizeOf(context).width < 460;
    void openSettings() =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(app: app)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
      child: Row(children: [
        const Mark(size: 18),
        const SizedBox(width: 10),
        Text('H11', style: T.title(c, size: 21).copyWith(letterSpacing: -.2)),
        const Spacer(),
        // On phones and the small window, the bar stays compact so it never
        // overflows: an icon for Settings, a short "New".
        if (desktopBar != null) desktopBar!,
        if (narrow)
          Tooltip(
            message: 'Settings',
            child: InkButton('', lead: Icon(Icons.tune_rounded, size: 18, color: c.ink), onTap: openSettings),
          )
        else
          InkButton('Settings', onTap: openSettings),
        AccentChip(narrow ? '+ New' : 'New page', onTap: onNew),
      ]),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final AppController app;
  const _StatusLine({required this.app});
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final st = app.engine.status;
    final desktop = app.engine is HostEngine;
    final (String text, bool on) = switch (st.state) {
      LinkState.connected => ('Linked with ${st.peerName}', true),
      LinkState.searching => (
          desktop ? 'Waiting for your phone' : 'Looking for ${st.peerName ?? 'your computer'}…',
          false
        ),
      LinkState.unpaired => (
          desktop ? 'No phone linked yet' : 'Not linked — pages stay on this phone',
          false
        ),
    };
    final receiving = app.engine.progress.length;
    return InkWell(
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => LinkScreen(app: app))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
        child: Row(children: [
          BreathingDot(live: on, color: c.linked, idle: c.faint),
          const SizedBox(width: 4),
          Expanded(child: Text(text, style: T.meta(c).copyWith(color: on ? c.linked : null), overflow: TextOverflow.ellipsis)),
          if (receiving > 0) Text('receiving $receiving', style: T.meta(c).copyWith(color: c.accent)),
          if (st.state == LinkState.unpaired)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: c.rule),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text('Link →', style: T.meta(c).copyWith(color: c.ink)),
            ),
        ]),
      ),
    );
  }
}

class _IndexColumn extends StatelessWidget {
  final AppController app;
  final List<Session> items;
  final String? selected;
  final void Function(String id) onOpen;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onQuery;
  final bool empty;
  final VoidCallback onNew;

  const _IndexColumn({
    required this.app,
    required this.items,
    required this.selected,
    required this.onOpen,
    required this.search,
    required this.searchFocus,
    required this.onQuery,
    required this.empty,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    if (empty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 48, 28, 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Entrance(child: Text('A blank page.',
              style: T.title(c, size: 30).copyWith(fontWeight: FontWeight.w700))),
          const SizedBox(height: 14),
          Text('Write an idea, attach anything — photos, video, documents.\n'
              'It appears on your other device the moment both are open.',
              style: T.ui(c, size: 14.5, color: c.pencil).copyWith(height: 1.55)),
          const SizedBox(height: 28),
          Entrance(delay: const Duration(milliseconds: 160), child: BlockButton('Start writing', onTap: onNew)),
        ]),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Row(children: [
          Text('INDEX', style: T.label(c)),
          const SizedBox(width: 14),
          Expanded(
            child: TextField(
              controller: search,
              focusNode: searchFocus,
              onChanged: onQuery,
              style: T.ui(c, size: 13.5),
              decoration: InputDecoration(
                hintText: 'Search',
                hintStyle: T.ui(c, size: 13.5, color: c.faint),
              ),
            ),
          ),
          Text('${items.length}', style: T.meta(c)),
        ]),
      ),
      const Hairline(),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 40),
          itemCount: items.length,
          separatorBuilder: (_, __) => const Hairline(indent: 18),
          itemBuilder: (_, i) => Entrance(
            key: ValueKey(items[i].id),
            delay: Duration(milliseconds: 40 * (i < 12 ? i : 12)),
            child: Dismissible(
              key: ValueKey('swipe-${items[i].id}'),
              direction: DismissDirection.horizontal,
              background: const _SwipeBg(alignStart: true),
              secondaryBackground: const _SwipeBg(alignStart: false),
              confirmDismiss: (_) => deleteWithChoice(context, app, items[i]),
              child: _Row(
                s: items[i],
                selected: items[i].id == selected,
                onTap: () => onOpen(items[i].id),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _Row extends StatelessWidget {
  final Session s;
  final bool selected;
  final VoidCallback onTap;
  const _Row({required this.s, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final preview = s.body
        .trim()
        .replaceAll(RegExp(r'\s*\n\s*'), '  ·  ')
        .replaceAll(RegExp(r'[ \t]+'), ' ');
    final dir = dirOf(s.displayTitle, dirOf(s.body, TextDirection.ltr));
    final showPreview = s.title.trim().isNotEmpty && preview.isNotEmpty;
    return Pressable(
      onTap: onTap,
      radius: BorderRadius.zero,
      pressedScale: 1, // rows don't shrink: only a soft tint on press
      child: AnimatedContainer(
        duration: Motion.base,
        curve: Motion.ease,
        decoration: BoxDecoration(
          color: selected ? c.sheet : null,
          border: BorderDirectional(start: BorderSide(color: c.tagFor(s.id), width: selected ? 5 : 3)),
        ),
        padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 18, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 52,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(shortDate(s.rev.u), style: T.meta(c)),
            ),
          ),
          Expanded(
            child: Directionality(
            textDirection: dir,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.displayTitle, style: T.rowTitle(c), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (showPreview) ...[
                const SizedBox(height: 3),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.ui(c, size: 13.5, color: c.pencil)),
              ],
              if (s.attachments.isNotEmpty || s.translation != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  if (s.attachments.isNotEmpty)
                    Text('${s.attachments.length} ${s.attachments.length == 1 ? 'file' : 'files'}',
                        style: T.meta(c)),
                  if (s.attachments.isNotEmpty && s.translation != null)
                    Text('  ·  ', style: T.meta(c)),
                  if (s.translation != null)
                    Text(s.translation!.to == 'ar' ? 'with Arabic' : 'with English', style: T.meta(c)),
                ]),
              ],
            ]),
            ),
          ),
        ]),
      ),
    );
  }
}

enum DeleteChoice { keep, here, both }

/// Asks before deleting: here only, or on both devices.
/// Used by swipe-to-delete and the page menu.
Future<DeleteChoice> askDelete(BuildContext context, String title) async {
  final c = context.ink;
  final r = await showDialog<DeleteChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.paper,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.rule)),
      title: Text('Delete this page?', style: T.title(c, size: 20)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('“$title”', style: T.ui(c, w: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 12),
        Text('Here only: your other device keeps its copy.\n'
            'Both devices: removed everywhere (the other device too, as soon as it connects).',
            style: T.ui(c, size: 13.5, color: c.pencil).copyWith(height: 1.55)),
      ]),
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        Wrap(alignment: WrapAlignment.end, children: [
          InkButton('Keep', onTap: () => Navigator.pop(ctx, DeleteChoice.keep)),
          InkButton('Here only', danger: true, onTap: () => Navigator.pop(ctx, DeleteChoice.here)),
          InkButton('Both devices', danger: true, strong: true,
              onTap: () => Navigator.pop(ctx, DeleteChoice.both)),
        ]),
      ],
    ),
  );
  return r ?? DeleteChoice.keep;
}

/// Asks, then deletes. Returns true if something was deleted.
Future<bool> deleteWithChoice(BuildContext context, AppController app, Session s) async {
  final choice = await askDelete(context, s.displayTitle);
  switch (choice) {
    case DeleteChoice.keep:
      return false;
    case DeleteChoice.here:
      await app.store.deleteLocal(s.id);
      app.toast('Deleted here. Your other device keeps it.');
    case DeleteChoice.both:
      await app.store.purgeEverywhere(s.id);
      app.toast(app.engine.status.state == LinkState.connected
          ? 'Deleted on both devices'
          : 'Deleted here — the other device will delete it when it connects');
  }
  return true;
}

class _SwipeBg extends StatelessWidget {
  final bool alignStart;
  const _SwipeBg({required this.alignStart});
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Container(
      color: c.danger.withValues(alpha: .1),
      alignment: alignStart ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Text('Delete', style: T.ui(c, size: 13.5, w: FontWeight.w700, color: c.danger)),
    );
  }
}

class _Blank extends StatelessWidget {
  const _Blank();
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return PaperBackground(
      child: Center(
        child: Text('Choose a page, or press Ctrl + N.',
            style: T.ui(c, size: 14, color: c.faint)),
      ),
    );
  }
}
