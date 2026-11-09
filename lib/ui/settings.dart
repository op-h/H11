import 'dart:io';

import 'package:flutter/material.dart';

import '../core/assistant.dart';
import '../core/translate.dart' show translationModel, EngineChoice;
import '../core/sync.dart' show LinkState;
import 'controller.dart';
import 'link_screen.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  final AppController app;
  const SettingsScreen({super.key, required this.app});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _key = TextEditingController();
  bool _startup = false;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_r);
    if (Platform.isWindows) _readStartup();
  }

  void _r() => mounted ? setState(() {}) : null;

  @override
  void dispose() {
    app.removeListener(_r);
    _key.dispose();
    super.dispose();
  }

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  Future<void> _readStartup() async {
    final r = await Process.run('reg', ['query', _runKey, '/v', 'H11']);
    if (mounted) setState(() => _startup = r.exitCode == 0);
  }

  Future<void> _setStartup(bool on) async {
    if (on) {
      await Process.run('reg', [
        'add', _runKey, '/v', 'H11', '/t', 'REG_SZ', '/d',
        '"${Platform.resolvedExecutable}" --hidden', '/f'
      ]);
    } else {
      await Process.run('reg', ['delete', _runKey, '/v', 'H11', '/f']);
    }
    await _readStartup();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(children: [InkButton('Back', onTap: () => Navigator.pop(context))]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Settings', style: T.title(c, size: 28)),
                      const SizedBox(height: 30),
                      _label(c, 'TRANSLATION'),
                      Text(
                          'Arabic ⇄ English. Free out of the box — no key needed. '
                          'The translation is saved with the page, so both devices show it.',
                          style: T.ui(c, size: 14, color: c.pencil).copyWith(height: 1.55)),
                      const SizedBox(height: 12),
                      for (final e in EngineChoice.values) _engineRow(c, e),
                      const SizedBox(height: 18),
                      _KeyField(
                        title: 'DeepL key (free)',
                        hint: 'DeepL API Free key  (…:fx)',
                        help: 'Best free quality · 500,000 characters a month · get one at deepl.com/pro-api',
                        saved: app.hasDeeplKey,
                        onSave: app.setDeeplKey,
                      ),
                      const SizedBox(height: 14),
                      _KeyField(
                        title: 'Claude key (optional, paid)',
                        hint: 'Anthropic API key  (sk-ant-…)',
                        help: 'Uses $translationModel · console.anthropic.com',
                        saved: app.hasApiKey,
                        onSave: app.setApiKey,
                      ),
                      if (app.hasApiKey || app.hasDeeplKey)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: InkButton('Send keys to linked device', accent: true, onTap: () async {
                            final ok = await app.shareApiKey();
                            app.toast(ok
                                ? 'Keys sent over the encrypted link'
                                : 'Your other device is not connected');
                          }),
                        ),
                      const SizedBox(height: 34),
                      _switchRow(c, 'Hide translations by default (show per page)',
                          app.hideTranslationsByDefault, app.setHideTranslationsByDefault),
                      const SizedBox(height: 34),
                      _label(c, 'WRITING ASSISTANT'),
                      _AssistantSettings(app: app),
                      const SizedBox(height: 34),
                      _label(c, 'LINK'),
                      _row(c, 'Devices and pairing', {LinkState.connected: "linked", LinkState.searching: "waiting", LinkState.unpaired: "not linked"}[app.engine.status.state]!, () {
                        Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => LinkScreen(app: app)));
                      }),
                      if (Platform.isWindows) ...[
                        const SizedBox(height: 34),
                        _label(c, 'THIS COMPUTER'),
                        _switchRow(c, 'Start with Windows, in the tray', _startup, _setStartup),
                        _row(c, 'Open H11 from anywhere', 'Ctrl + Alt + M', null),
                        _row(c, 'Open the files folder', '', () {
                          Process.run('explorer.exe', [app.dataDir.path]);
                        }),
                      ],
                      const SizedBox(height: 34),
                      _label(c, 'GOOD TO KNOW'),
                      Text(
                          '• Deleting a page removes it from this device only. The other device keeps it.\n'
                          '• Files keep their original format and name.\n'
                          '• Your keys never leave the system keystore.\n'
                          '• Shortcuts: Ctrl+N new page · Ctrl+F search · Ctrl+O attach · Ctrl+T translate.',
                          style: T.ui(c, size: 13.5, color: c.pencil).copyWith(height: 1.75)),
                      const SizedBox(height: 26),
                      Text('H11 1.0 · device key ${app.fingerprint}', style: T.meta(c)),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _engineRow(Palette c, EngineChoice e) {
    final (title, sub) = switch (e) {
      EngineChoice.auto => ('Automatic', 'DeepL if a key is saved, otherwise Google · now: ${app.activeEngineName}'),
      EngineChoice.google => ('Google Translate', 'Free, no key'),
      EngineChoice.deepl => ('DeepL', app.hasDeeplKey ? 'Free key saved' : 'Needs a free key below'),
      EngineChoice.claude => ('Claude', app.hasApiKey ? 'Key saved' : 'Needs your Anthropic key below'),
    };
    final on = app.engineChoice == e;
    return InkWell(
      onTap: () => app.setEngine(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: on ? c.accent : c.faint, width: on ? 5 : 1.5),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: T.ui(c, size: 14.5, w: on ? FontWeight.w600 : FontWeight.w400)),
              const SizedBox(height: 2),
              Text(sub, style: T.meta(c)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _label(Palette c, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s, style: T.label(c)),
          const SizedBox(height: 8),
          const Hairline(),
        ]),
      );

  Widget _row(Palette c, String title, String value, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(children: [
            Expanded(child: Text(title, style: T.ui(c, size: 14.5))),
            Text(value, style: T.meta(c)),
            if (onTap != null) Text('  →', style: T.meta(c).copyWith(color: c.ink)),
          ]),
        ),
      );

  Widget _switchRow(Palette c, String title, bool v, ValueChanged<bool> on) => InkWell(
        onTap: () => on(!v),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(children: [
            Expanded(child: Text(title, style: T.ui(c, size: 14.5))),
            Text(v ? 'On' : 'Off', style: T.meta(c).copyWith(color: v ? c.linked : null)),
          ]),
        ),
      );
}


class _KeyField extends StatefulWidget {
  final String title;
  final String hint;
  final String help;
  final bool saved;
  final Future<void> Function(String?) onSave;
  const _KeyField(
      {required this.title, required this.hint, required this.help, required this.saved, required this.onSave});
  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  final _ctl = TextEditingController();
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.title, style: T.ui(c, size: 13.5, w: FontWeight.w600)),
      const SizedBox(height: 6),
      if (widget.saved)
        Row(children: [
          Expanded(child: Text('Saved in the system keystore', style: T.meta(c).copyWith(color: c.linked))),
          InkButton('Remove', danger: true, onTap: () => widget.onSave(null)),
        ])
      else
        Row(children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: c.sheet,
                border: Border.all(color: c.rule),
                borderRadius: BorderRadius.circular(6),
              ),
              child: TextField(
                controller: _ctl,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                style: T.meta(c).copyWith(color: c.ink, fontSize: 13),
                decoration: InputDecoration(hintText: widget.hint, hintStyle: T.meta(c).copyWith(fontSize: 13)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          BlockButton('Save', onTap: () async {
            await widget.onSave(_ctl.text);
            _ctl.clear();
          }),
        ]),
      const SizedBox(height: 5),
      Text(widget.help, style: T.meta(c)),
    ]);
  }
}


/// Pick a provider (DeepSeek first), a model and a key. "Test" makes a
/// tiny request so mistakes show up here, not mid-writing.
class _AssistantSettings extends StatefulWidget {
  final AppController app;
  const _AssistantSettings({required this.app});
  @override
  State<_AssistantSettings> createState() => _AssistantSettingsState();
}

class _AssistantSettingsState extends State<_AssistantSettings> {
  static const _choices = <String>[
    'DeepSeek', 'OpenAI', 'OpenRouter', 'Groq', 'Mistral', 'Ollama (this computer)', 'Claude', 'Gemini', 'Custom',
  ];
  late String _choice;
  final _model = TextEditingController();
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _testing = false;
  String? _testResult;
  bool _ok = false;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    final cfg = app.aiConfig;
    _model.text = cfg.model;
    _url.text = cfg.baseUrl;
    _choice = switch (cfg.provider) {
      AiProvider.claude => 'Claude',
      AiProvider.gemini => 'Gemini',
      AiProvider.openai => aiPresets.entries
              .where((e) => cfg.baseUrl.startsWith(e.value.$1))
              .map((e) => e.key)
              .firstOrNull ??
          'Custom',
    };
  }

  @override
  void dispose() {
    _model.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  AiProvider get _provider => switch (_choice) {
        'Claude' => AiProvider.claude,
        'Gemini' => AiProvider.gemini,
        _ => AiProvider.openai,
      };

  void _pick(String c) {
    setState(() {
      _choice = c;
      _testResult = null;
      final preset = aiPresets[c];
      if (preset != null) {
        _url.text = preset.$1;
        _model.text = preset.$2;
      } else if (c == 'Claude' || c == 'Gemini') {
        _url.text = '';
        _model.text = defaultModel(_provider);
      }
    });
  }

  AiConfig _build() => AiConfig(
        provider: _provider,
        model: _model.text.trim(),
        key: _key.text.trim().isNotEmpty ? _key.text.trim() : app.aiConfig.key,
        baseUrl: _provider == AiProvider.openai ? _url.text.trim() : '',
      );

  Future<void> _save() async {
    final cfg = AiConfig.fromJson(_build().toJson());
    if (cfg == null) {
      setState(() {
        _ok = false;
        _testResult = 'Check the address (must start with https://) and the model name.';
      });
      return;
    }
    await app.setAiConfig(cfg);
    _key.clear();
    setState(() {
      _ok = true;
      _testResult = 'Saved.';
    });
  }

  Future<void> _test() async {
    await _save();
    if (!_ok) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final out = await app.assist('Reply with exactly: OK', 'test');
      _ok = true;
      _testResult = 'Working ✓  (${out.length > 40 ? out.substring(0, 40) : out})';
    } catch (e) {
      _ok = false;
      _testResult = '$e';
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _field(Palette c, TextEditingController ctl, String hint, {bool secret = false}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: c.sheet,
          border: Border.all(color: c.rule),
          borderRadius: BorderRadius.circular(6),
        ),
        child: TextField(
          controller: ctl,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: false,
          style: T.meta(c).copyWith(color: c.ink, fontSize: 13),
          decoration: InputDecoration(hintText: hint, hintStyle: T.meta(c).copyWith(fontSize: 13)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    final cfg = app.aiConfig;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          'The Assist button on every page (Ctrl+J) opens a floating window: pick an action or '
          'type your own, edit the suggestion, then approve it. Your text is sent only to the '
          'provider you choose.',
          style: T.ui(c, size: 14, color: c.pencil).copyWith(height: 1.55)),
      const SizedBox(height: 12),
      Text(cfg.ready ? 'Active: ${cfg.label}' : 'Not set up yet',
          style: T.meta(c).copyWith(color: cfg.ready ? c.linked : c.danger)),
      const SizedBox(height: 12),
      Wrap(children: [
        for (final ch in _choices) InkButton(ch, accent: ch == _choice, strong: ch == _choice, onTap: () => _pick(ch)),
      ]),
      const SizedBox(height: 12),
      if (_choice == 'DeepSeek') ...[
        Wrap(children: [
          InkButton('deepseek-chat · fast', accent: _model.text == 'deepseek-chat',
              onTap: () => setState(() => _model.text = 'deepseek-chat')),
          InkButton('deepseek-reasoner · thinks first', accent: _model.text == 'deepseek-reasoner',
              onTap: () => setState(() => _model.text = 'deepseek-reasoner')),
        ]),
        const SizedBox(height: 8),
      ],
      if (_provider == AiProvider.openai) _field(c, _url, 'API address, e.g. https://api.deepseek.com/v1'),
      _field(c, _model, 'Model name'),
      _field(c, _key, cfg.key.isNotEmpty ? 'Key saved — type to replace' : 'API key', secret: true),
      Row(children: [
        BlockButton(_testing ? 'Testing…' : 'Save & test', onTap: _testing ? null : _test),
        const SizedBox(width: 8),
        InkButton('Save only', onTap: _save),
        if (cfg.key.isNotEmpty)
          InkButton('Remove key', danger: true, onTap: () async {
            await app.setAiConfig(AiConfig(provider: cfg.provider, model: cfg.model, key: '', baseUrl: cfg.baseUrl));
            setState(() => _testResult = 'Key removed.');
          }),
      ]),
      if (_testResult != null) ...[
        const SizedBox(height: 8),
        Text(_testResult!, style: T.meta(c).copyWith(color: _ok ? c.linked : c.danger)),
      ],
      const SizedBox(height: 6),
      Text(
          _choice == 'DeepSeek'
              ? 'Get a key at platform.deepseek.com → API keys.'
              : _choice == 'OpenRouter'
                  ? 'One key, hundreds of models: openrouter.ai/keys.'
                  : _choice.startsWith('Ollama')
                      ? 'Runs on your computer, no key, fully private (install Ollama first).'
                      : '',
          style: T.meta(c)),
    ]);
  }
}
