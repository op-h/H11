import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../core/model.dart';
import '../core/sync.dart';
import '../core/translate.dart';
import 'assistant_panel.dart';
import 'controller.dart';
import 'motion.dart';
import 'home.dart' show fullDate, deleteWithChoice;
import 'theme.dart';

final _arabicChar = RegExp(r'[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]');
final _latinChar = RegExp(r'[A-Za-z]');

/// Direction of the first strong character, so Arabic flows right-to-left
/// and English left-to-right without any setting.
TextDirection dirOf(String s, TextDirection fallbackDir) {
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (_arabicChar.hasMatch(ch)) return TextDirection.rtl;
    if (_latinChar.hasMatch(ch)) return TextDirection.ltr;
  }
  return fallbackDir;
}

String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

class PageScreen extends StatefulWidget {
  final AppController app;
  final String id;
  final bool autofocus;
  final bool standalone;
  const PageScreen(
      {super.key, required this.app, required this.id, this.autofocus = false, this.standalone = false});
  @override
  State<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends State<PageScreen> {
  late Session s;
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _bodyFocus = FocusNode();
  Timer? _debounce;
  StreamSubscription? _sub;
  bool _stale = false;
  bool _assistOpen = false;
  TextSelection? _assistSel; // what the assistant is working on
  bool _dirty = false;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    s = app.store.get(widget.id)!;
    _title.text = s.title;
    _body.text = s.body;
    _checkStale();
    _sub = app.store.changes.listen(_onStoreChange);
    app.addListener(_onApp);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bodyFocus.requestFocus());
    }
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  void _onStoreChange(Session? changed) {
    if (!mounted) return;
    final fresh = app.store.get(widget.id);
    if (fresh == null) {
      if (widget.standalone) Navigator.of(context).maybePop();
      return;
    }
    // Edit arrived from the other device: show it live.
    if (fresh.rev.d != app.identity.deviceId && !_dirty) {
      if (_title.text != fresh.title) _title.value = _keepCursor(_title.value, fresh.title);
      if (_body.text != fresh.body) _body.value = _keepCursor(_body.value, fresh.body);
    }
    s = fresh;
    _checkStale();
    setState(() {});
  }

  TextEditingValue _keepCursor(TextEditingValue old, String text) {
    final o = old.selection.baseOffset.clamp(0, text.length);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: o));
  }

  Future<void> _checkStale() async {
    final v = await app.translationIsStale(s);
    if (mounted && v != _stale) setState(() => _stale = v);
  }

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _save);
    setState(() {}); // direction may flip
  }

  Future<void> _save() async {
    _debounce?.cancel();
    if (!_dirty) return;
    _dirty = false;
    final cur = app.store.get(widget.id);
    if (cur == null) return;
    cur.title = _title.text;
    cur.body = _body.text;
    await app.store.saveLocal(cur);
  }

  @override
  void dispose() {
    _save();
    _sub?.cancel();
    app.removeListener(_onApp);
    _debounce?.cancel();
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final FilePickerResult? r;
    try {
      r = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: false,
        // The phone copies big files before handing them over: show that.
        onFileLoading: (st) => app.setPreparing(widget.id, st == FilePickerStatus.picking),
      );
    } finally {
      app.setPreparing(widget.id, false);
    }
    if (r == null) return;
    final files = <(File, String)>[];
    for (final f in r.files) {
      if (f.path != null) files.add((File(f.path!), f.name));
    }
    await _save();
    final cur = app.store.get(widget.id)!;
    unawaited(app.addFiles(cur, files)); // runs in the background
  }

  void _openAssistant() {
    final sel = _body.selection;
    final has = sel.isValid && !sel.isCollapsed;
    setState(() {
      _assistSel = has ? sel : null;
      _assistOpen = true;
    });
  }

  void _applyAssist(AssistResult r) {
    final text = _body.text;
    final sel = _assistSel;
    String next;
    int caret;
    if (r.insert) {
      final at = sel?.end ?? text.length;
      final add = '${at > 0 && !text.substring(0, at).endsWith('\n') ? '\n\n' : ''}${r.text}';
      next = text.replaceRange(at, at, add);
      caret = at + add.length;
    } else if (sel != null && sel.end <= text.length) {
      next = text.replaceRange(sel.start, sel.end, r.text);
      caret = sel.start + r.text.length;
    } else {
      next = r.text;
      caret = next.length;
    }
    _body.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: caret));
    _changed();
    setState(() => _assistOpen = false);
    app.toast(r.insert ? 'Added to the page' : 'Page updated');
  }

  Future<void> _translate() async {
    await _save();
    try {
      await app.translate(app.store.get(widget.id)!);
    } on TranslateError catch (e) {
      app.toast(e.message);
    } catch (e) {
      app.toast('Translation failed: $e');
    }
  }

  Future<void> _open(Attachment a) async {
    final f = await app.store.findBlob(a.sha);
    if (f == null) {
      app.toast(app.engine.status.state == LinkState.connected
          ? 'Still arriving…'
          : 'This file is on your other device. Open H11 there to fetch it.');
      return;
    }
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [f.path]);
    } else {
      final res = await OpenFilex.open(f.path);
      if (res.type != ResultType.done) app.toast('No app on this device opens .${a.ext} files');
    }
  }

  Future<void> _saveAll() async {
    if (!Platform.isAndroid) {
      // Computer: pick a folder once, copy everything into it.
      final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Save all files to…');
      if (dir == null) return;
      var n = 0, missing = 0;
      for (final a in s.attachments) {
        final f = await app.store.findBlob(a.sha);
        if (f == null) {
          missing++;
          continue;
        }
        var target = File('$dir${Platform.pathSeparator}${a.name}');
        var i = 1;
        while (await target.exists()) {
          final dot = a.name.lastIndexOf('.');
          final base = dot > 0 ? a.name.substring(0, dot) : a.name;
          final ext = dot > 0 ? a.name.substring(dot) : '';
          target = File('$dir${Platform.pathSeparator}$base ($i)$ext');
          i++;
        }
        await f.copy(target.path);
        n++;
      }
      if (Platform.isWindows) await Process.run('explorer.exe', [dir]);
      app.toast('Saved $n ${n == 1 ? 'file' : 'files'}'
          '${missing > 0 ? ' · $missing still on the other device' : ''}');
      return;
    }
    var saved = 0, missing = 0;
    for (final a in s.attachments) {
      if (!await app.store.hasBlob(a.sha)) {
        missing++;
        continue;
      }
      try {
        if (await app.saveAttachment(a) != null) saved++;
      } catch (_) {}
    }
    app.toast('Saved $saved ${saved == 1 ? 'file' : 'files'}'
        '${Platform.isAndroid ? ' to Downloads/H11' : ''}'
        '${missing > 0 ? ' · $missing still on the other device' : ''}');
  }

  Future<void> _delete() async {
    _debounce?.cancel();
    await _save();
    if (!mounted) return;
    await deleteWithChoice(context, app, app.store.get(widget.id) ?? s);
  }

  int _words(String t) => RegExp(r'\S+').allMatches(t).length;

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final base = Directionality.of(context);
    final titleDir = dirOf(_title.text, dirOf(_body.text, base));
    final bodyDir = dirOf(_body.text, titleDir);
    final busy = app.translating.contains(s.id);
    final n = s.attachments.length;
    final meta = '${fullDate(s.created)} · ${_words(_body.text)} words'
        '${n == 0 ? '' : ' · $n ${n == 1 ? 'file' : 'files'}'}';

    final page = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): _translate,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _attach,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): _openAssistant,
      },
      child: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 48),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    TextField(
                      controller: _title,
                      onChanged: (_) => _changed(),
                      textDirection: titleDir,
                      style: T.title(c),
                      maxLines: null,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => _bodyFocus.requestFocus(),
                      decoration: InputDecoration(
                          hintText: 'Title', hintStyle: T.title(c).copyWith(color: c.faint)),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: c.tagFor(s.id), borderRadius: BorderRadius.circular(2)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(meta, style: T.meta(c))),
                    ]),
                    const SizedBox(height: 22),
                    TextField(
                      controller: _body,
                      focusNode: _bodyFocus,
                      onChanged: (_) => _changed(),
                      textDirection: bodyDir,
                      style: T.body(c),
                      maxLines: null,
                      minLines: 8,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                          hintText: 'Write…', hintStyle: T.body(c).copyWith(color: c.faint)),
                    ),
                    if (s.attachments.isNotEmpty ||
                        (app.importing[s.id]?.isNotEmpty ?? false) ||
                        app.preparing.contains(s.id)) ...[
                      const SizedBox(height: 34),
                      _Section('ATTACHED'),
                      if (app.preparing.contains(s.id)) const _BusyRow('Preparing files…'),
                      for (final n in app.importing[s.id] ?? const <String>[])
                        _BusyRow('Adding $n…'),
                      for (final a in s.attachments)
                        _AttachmentRow(
                          app: app,
                          a: a,
                          sessionId: widget.id,
                          onOpen: () => _open(a),
                          onRemove: () => app.removeAttachment(app.store.get(widget.id)!, a),
                        ),
                    ],
                    if (s.translation != null || busy) ...[
                      const SizedBox(height: 34),
                      AnimatedSize(
                        duration: Motion.base,
                        curve: Motion.ease,
                        alignment: Alignment.topCenter,
                        child: _TranslationBlock(
                        t: s.translation,
                        busy: busy,
                        stale: _stale,
                        onRedo: _translate,
                        hidden: app.translationHidden(s.id) && !busy,
                        onToggle: () => app.toggleTranslation(s.id),
                      ),
                      ),
                    ],
                  ]),
                ),
              ),
            ],
          ),
        ),
        const Hairline(),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(children: [
            // On a phone these don't all fit: they scroll sideways, and a
            // soft fade at the edge shows there is more.
            Expanded(
              child: ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  colors: [Colors.black, Colors.black, Colors.transparent],
                  stops: [0, .92, 1],
                ).createShader(r),
                blendMode: BlendMode.dstIn,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: 18),
                  child: Row(children: [
                    if (widget.standalone)
                      InkButton('Back', onTap: () => Navigator.of(context).maybePop()),
                    InkButton('Attach', onTap: _attach),
                    InkButton('Assist', accent: true, onTap: _openAssistant),
                    InkButton(
                      busy
                          ? 'Translating…'
                          : 'Translate → ${targetFor('${_title.text}\n${_body.text}') == 'ar' ? 'العربية' : 'English'}',
                      onTap: busy ? null : _translate,
                    ),
                  ]),
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              color: c.sheet,
              elevation: 2,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(2), side: BorderSide(color: c.rule)),
              onSelected: (v) {
                if (v == 'delete') _delete();
                if (v == 'saveall') _saveAll();
                if (v == 'copy') {
                  Clipboard.setData(ClipboardData(text: '${_title.text}\n\n${_body.text}'.trim()));
                  app.toast('Copied');
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'copy', child: Text('Copy text', style: T.ui(c))),
                if (s.attachments.isNotEmpty)
                  PopupMenuItem(value: 'saveall', child: Text('Save all files', style: T.ui(c))),
                PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete…', style: T.ui(c, color: c.danger))),
              ],
              child: Container(
                margin: const EdgeInsets.all(2),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(color: c.rule),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('More', style: T.ui(c, size: 13.5, w: FontWeight.w500)),
              ),
            ),
          ]),
        ),
      ]),
    );

    final sel = _assistSel;
    final layered = Stack(children: [
      page,
      if (_assistOpen)
        Positioned.fill(
          child: Entrance(
            dy: 28,
            duration: Motion.page,
            child: AssistantPanel(
            app: app,
            source: sel != null && sel.end <= _body.text.length
                ? sel.textInside(_body.text)
                : [_title.text, _body.text].where((e) => e.trim().isNotEmpty).join('\n\n'),
            isSelection: sel != null,
            onApply: _applyAssist,
            onClose: () => setState(() => _assistOpen = false),
          ),
          ),
        ),
    ]);
    if (!widget.standalone) return layered;
    return PopScope(
      onPopInvokedWithResult: (_, __) => _save(),
      child: Scaffold(body: SafeArea(child: layered)),
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  const _Section(this.label);
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: T.label(c)),
        const SizedBox(height: 8),
        const Hairline(),
      ]),
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  final AppController app;
  final Attachment a;
  final String sessionId;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  const _AttachmentRow(
      {required this.app,
      required this.a,
      required this.sessionId,
      required this.onOpen,
      required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final p = app.engine.progress[a.sha];
    final file = app.store.blobFile(a);
    final present = file.existsSync();
    final ext = a.ext.isEmpty ? 'FILE' : a.ext.toUpperCase();
    final state = present
        ? fmtSize(a.size)
        : p != null
            ? '${(p * 100).floor()}%'
            : 'on other device';
    return InkWell(
      onTap: onOpen,
      onLongPress: () => _confirmRemove(context),
      onSecondaryTap: () => _confirmRemove(context),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.rule))),
        child: Row(children: [
          SizedBox(
            width: 46,
            height: 46,
            child: present && a.isImage
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Image.file(file, fit: BoxFit.cover, cacheWidth: 140,
                        errorBuilder: (_, __, ___) => _Tag(ext)),
                  )
                : _Tag(ext),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name, style: T.ui(c, size: 14, w: FontWeight.w500),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text(state, style: T.meta(c).copyWith(color: p != null ? c.accent : null)),
              if (p != null) ...[
                const SizedBox(height: 6),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: p),
                  duration: Motion.base,
                  builder: (_, v, __) => LinearProgressIndicator(
                    value: v,
                    minHeight: 2,
                    borderRadius: BorderRadius.circular(2),
                    backgroundColor: c.rule,
                    color: c.accent,
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 10),
          _action(context, c, present, p),
        ]),
      ),
    );
  }

  Widget _action(BuildContext context, Palette c, bool present, double? p) {
    if (present) {
      return _Pill(label: 'Save', filled: false, onTap: () async {
        try {
          final where = await app.saveAttachment(a);
          if (where != null) app.toast('Saved to $where');
        } catch (e) {
          app.toast('Could not save: $e');
        }
      });
    }
    if (p != null) return _Pill(label: '${(p * 100).floor()}%', filled: false, onTap: null);
    final linked = app.engine.status.state == LinkState.connected;
    return _Pill(
      label: 'Download',
      filled: true,
      onTap: linked
          ? () => app.engine.fetchMissing(app.store.get(sessionId)!)
          : () => app.toast('Open H11 on your other device to download this file'),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final c = context.ink;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.sheet,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
        title: Text('Remove ${a.name}?', style: T.title(c, size: 18)),
        content: Text('It is removed from this page.', style: T.ui(c, color: c.pencil)),
        actions: [
          InkButton('Keep', onTap: () => Navigator.pop(ctx, false)),
          InkButton('Remove', danger: true, strong: true, onTap: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true) onRemove();
  }
}

class _BusyRow extends StatelessWidget {
  final String text;
  const _BusyRow(this.text);
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.rule))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: T.ui(c, size: 14, w: FontWeight.w500),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        LinearProgressIndicator(minHeight: 2, backgroundColor: c.rule, color: c.accent),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback? onTap;
  const _Pill({required this.label, required this.filled, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final fg = filled ? c.onAccent : (onTap == null ? c.faint : c.accent);
    return Material(
      color: filled ? c.accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: filled ? BorderSide.none : BorderSide(color: onTap == null ? c.rule : c.accent),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(label, style: T.ui(c, size: 12.5, w: FontWeight.w600, color: fg)),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String ext;
  const _Tag(this.ext);
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(ext.length > 4 ? ext.substring(0, 4) : ext,
          style: T.meta(c).copyWith(fontSize: 10, color: c.pencil, fontWeight: FontWeight.w500)),
    );
  }
}

class _TranslationBlock extends StatelessWidget {
  final Translation? t;
  final bool busy;
  final bool stale;
  final VoidCallback onRedo;
  final bool hidden;
  final VoidCallback onToggle;
  const _TranslationBlock(
      {required this.t,
      required this.busy,
      required this.stale,
      required this.onRedo,
      required this.hidden,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final toAr = t?.to == 'ar';
    final dir = toAr ? TextDirection.rtl : TextDirection.ltr;
    final canFold = t != null && !busy;
    final firstLine = (t?.text ?? '').trim().split('\n').first;

    return Container(
      decoration: BoxDecoration(
        color: c.sheet.withValues(alpha: .6),
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Header: the whole bar folds/unfolds the translation.
        Pressable(
          onTap: canFold ? onToggle : null,
          radius: BorderRadius.zero,
          pressedScale: 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(children: [
              Icon(Icons.translate_rounded, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: t == null ? 'Translation' : (toAr ? 'English → Arabic' : 'Arabic → English'),
                        style: T.ui(c, size: 13.5, w: FontWeight.w600)),
                    if (t?.by != null) TextSpan(text: '  ·  ${t!.by}', style: T.meta(c)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canFold && !hidden)
                InkButton('Copy', onTap: () {
                  Clipboard.setData(ClipboardData(text: t!.text));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Translation copied')));
                }),
              if (canFold)
                InkButton(
                  hidden ? 'Show' : 'Hide',
                  lead: AnimatedRotation(
                    turns: hidden ? -.25 : 0,
                    duration: Motion.base,
                    curve: Motion.ease,
                    child: Icon(Icons.expand_more_rounded, size: 18, color: c.ink),
                  ),
                  onTap: onToggle,
                ),
            ]),
          ),
        ),
        // Folded: one quiet line so you know it's there.
        if (hidden && t != null)
          Pressable(
            onTap: onToggle,
            radius: BorderRadius.zero,
            pressedScale: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(firstLine,
                  textDirection: dir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.ui(c, size: 13.5, color: c.faint)),
            ),
          ),
        if (!hidden) ...[
          Container(height: 1, color: c.rule),
          if (stale && !busy)
            Pressable(
              onTap: onRedo,
              radius: BorderRadius.zero,
              pressedScale: 1,
              child: Container(
                color: c.danger.withValues(alpha: .07),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Row(children: [
                  Icon(Icons.refresh_rounded, size: 16, color: c.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('The page changed since — tap to translate again',
                        style: T.ui(c, size: 13, color: c.danger)),
                  ),
                ]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            child: busy && t == null
                ? Text('Translating…', style: T.body(c).copyWith(color: c.faint))
                : Opacity(
                    opacity: busy ? .4 : 1,
                    child: SelectableText(
                      t?.text ?? '',
                      textDirection: dir,
                      style: T.body(c).copyWith(color: c.pencil),
                    ),
                  ),
          ),
        ],
      ]),
    );
  }
}
