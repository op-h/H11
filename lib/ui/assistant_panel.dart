import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/assistant.dart';
import 'controller.dart';
import 'theme.dart';

/// What the panel hands back when the user approves a result.
class AssistResult {
  final String text;
  final bool insert; // true: add below; false: replace
  const AssistResult(this.text, {required this.insert});
}

/// Floating, semi-transparent assistant window over the page.
/// Nothing changes in the page until the user presses Replace or Insert.
class AssistantPanel extends StatefulWidget {
  final AppController app;
  final String source; // selected text, or the whole page
  final bool isSelection;
  final void Function(AssistResult) onApply;
  final VoidCallback onClose;
  const AssistantPanel({
    super.key,
    required this.app,
    required this.source,
    required this.isSelection,
    required this.onApply,
    required this.onClose,
  });

  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final _custom = TextEditingController();
  final _result = TextEditingController();
  String? _instruction;
  bool _insertMode = false;
  bool _busy = false;
  String? _error;
  Offset _drag = Offset.zero;

  @override
  void dispose() {
    _custom.dispose();
    _result.dispose();
    super.dispose();
  }

  Future<void> _run(String instruction, {bool insert = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _instruction = instruction;
      _insertMode = insert;
    });
    try {
      final out = await widget.app.assist(instruction, widget.source);
      _result.text = out;
    } on AssistError catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final cfg = widget.app.aiConfig;
    final wide = MediaQuery.sizeOf(context).width > 700;
    final hasResult = _result.text.isNotEmpty && !_busy;

    final panel = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: wide ? 560 : double.infinity,
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          decoration: BoxDecoration(
            color: c.paper.withValues(alpha: .88),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.rule),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: .12), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Header (drag handle on the computer)
            GestureDetector(
              onPanUpdate: wide ? (d) => setState(() => _drag += d.delta) : null,
              child: MouseRegion(
                cursor: wide ? SystemMouseCursors.move : MouseCursor.defer,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(children: [
                    const Mark(size: 12),
                    const SizedBox(width: 10),
                    Text('Assistant', style: T.ui(c, size: 15, w: FontWeight.w700)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        cfg.ready ? cfg.label : 'not set up',
                        style: T.meta(c),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkButton('Close', onTap: widget.onClose),
                  ]),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                widget.isSelection
                    ? 'Working on the selected text (${widget.source.length} characters)'
                    : 'Working on the whole page',
                style: T.meta(c),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                children: [
                  Wrap(spacing: 0, runSpacing: 0, children: [
                    for (final a in assistActions)
                      InkButton(a.label,
                          accent: _instruction == a.instruction,
                          onTap: _busy || !cfg.ready ? null : () => _run(a.instruction, insert: a.insert)),
                  ]),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                    decoration: BoxDecoration(
                      color: c.sheet.withValues(alpha: .8),
                      border: Border.all(color: c.rule),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _custom,
                          enabled: cfg.ready && !_busy,
                          style: T.ui(c, size: 14),
                          minLines: 1,
                          maxLines: 3,
                          onSubmitted: (v) => v.trim().isEmpty ? null : _run(v.trim()),
                          decoration: InputDecoration(
                            hintText: 'Or tell it what to do… (any language)',
                            hintStyle: T.ui(c, size: 14, color: c.faint),
                          ),
                        ),
                      ),
                      InkButton('Ask', accent: true, onTap: _busy || !cfg.ready
                          ? null
                          : () {
                              final v = _custom.text.trim();
                              if (v.isNotEmpty) _run(v);
                            }),
                    ]),
                  ),
                  if (!cfg.ready) ...[
                    const SizedBox(height: 12),
                    Text('Add a DeepSeek (or other) key in Settings → Writing assistant.',
                        style: T.ui(c, size: 13.5, color: c.danger)),
                  ],
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(minHeight: 2, backgroundColor: c.rule, color: c.accent),
                    const SizedBox(height: 8),
                    Text('Thinking…', style: T.meta(c)),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: T.ui(c, size: 13.5, color: c.danger).copyWith(height: 1.45)),
                  ],
                  if (hasResult) ...[
                    const SizedBox(height: 14),
                    Text('SUGGESTION — EDIT IT IF YOU LIKE', style: T.label(c)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: c.sheet.withValues(alpha: .85),
                        border: Border.all(color: c.rule),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: TextField(
                        controller: _result,
                        maxLines: null,
                        style: T.body(c).copyWith(fontSize: 15.5),
                        textDirection: _dir(_result.text),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hasResult)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                child: Wrap(alignment: WrapAlignment.end, children: [
                  InkButton('Try again', onTap: () => _run(_instruction!, insert: _insertMode)),
                  InkButton('Copy', onTap: () {
                    Clipboard.setData(ClipboardData(text: _result.text));
                    widget.app.toast('Copied');
                  }),
                  InkButton('Insert below', onTap: () => widget.onApply(AssistResult(_result.text, insert: true))),
                  const SizedBox(width: 4),
                  BlockButton(_insertMode ? 'Add to page' : 'Replace',
                      onTap: () => widget.onApply(AssistResult(_result.text, insert: _insertMode))),
                ]),
              ),
          ]),
        ),
      ),
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: Transform.translate(
        offset: _drag,
        child: Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 64), child: panel),
      ),
    );
  }

  TextDirection _dir(String s) {
    for (final r in s.runes) {
      if (r >= 0x0600 && r <= 0x06FF) return TextDirection.rtl;
      if ((r >= 65 && r <= 90) || (r >= 97 && r <= 122)) return TextDirection.ltr;
    }
    return TextDirection.ltr;
  }
}
