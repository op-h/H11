import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/assistant.dart';
import '../core/identity.dart';
import '../core/model.dart';
import '../core/store.dart';
import '../core/sync.dart';
import '../core/translate.dart';
import 'vault.dart';

bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Everything the UI needs, in one place.
class AppController extends ChangeNotifier {
  late final Store store;
  late final SyncEngine engine;
  late final Vault vault;
  late final Identity identity;
  late final String fingerprint;
  String? _apiKey; // Claude
  String? _deeplKey;
  EngineChoice engineChoice = EngineChoice.auto;

  /// Writing assistant: DeepSeek out of the box (key added in Settings).
  AiConfig aiConfig = AiConfig(
      provider: AiProvider.openai,
      model: 'deepseek-chat',
      key: '',
      baseUrl: aiPresets['DeepSeek']!.$1);
  final Set<String> translating = {};

  /// Pages whose translation is folded away, and the global default.
  final Set<String> _hiddenTr = {};
  bool hideTranslationsByDefault = false;
  final Set<String> _shownTr = {}; // opened explicitly while default is "hidden"
  late File _prefsFile;

  bool translationHidden(String id) =>
      hideTranslationsByDefault ? !_shownTr.contains(id) : _hiddenTr.contains(id);

  Future<void> toggleTranslation(String id) async {
    if (hideTranslationsByDefault) {
      _shownTr.contains(id) ? _shownTr.remove(id) : _shownTr.add(id);
    } else {
      _hiddenTr.contains(id) ? _hiddenTr.remove(id) : _hiddenTr.add(id);
    }
    notifyListeners(); // update the screen first, then remember it
    await _savePrefs();
  }

  Future<void> setHideTranslationsByDefault(bool v) async {
    hideTranslationsByDefault = v;
    _shownTr.clear();
    notifyListeners();
    await _savePrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      if (await _prefsFile.exists()) {
        final j = jsonDecode(await _prefsFile.readAsString()) as Map<String, dynamic>;
        hideTranslationsByDefault = j['hideTr'] == true;
        _hiddenTr.addAll((j['hidden'] as List? ?? const []).whereType<String>());
        _shownTr.addAll((j['shown'] as List? ?? const []).whereType<String>());
      }
    } catch (_) {}
  }

  Future<void> _savePrefs() => _prefsFile.writeAsString(jsonEncode({
        'hideTr': hideTranslationsByDefault,
        'hidden': _hiddenTr.toList(),
        'shown': _shownTr.toList(),
      }));

  /// Files being added right now, per page: shown as "Adding…" rows.
  final Map<String, List<String>> importing = {};

  /// Pages whose file picker is still preparing the chosen files.
  final Set<String> preparing = {};

  void setPreparing(String id, bool on) {
    on ? preparing.add(id) : preparing.remove(id);
    notifyListeners();
  }
  final _subs = <StreamSubscription>[];
  final _toasts = StreamController<String>.broadcast();

  Stream<String> get toasts => _toasts.stream;
  bool get hasApiKey => (_apiKey ?? '').isNotEmpty;
  bool get hasDeeplKey => (_deeplKey ?? '').isNotEmpty;

  /// Name of the engine "auto" would use right now.
  String get activeEngineName => _service().chain.first.name;

  TranslationService _service() => TranslationService(
      choice: engineChoice, deeplKey: _deeplKey, claudeKey: _apiKey);

  Future<void> _loadKeys() async {
    _apiKey = await vault.read('apikey');
    _deeplKey = await vault.read('deeplkey');
    final e = await vault.read('engine');
    engineChoice = EngineChoice.values.firstWhere((x) => x.name == e, orElse: () => EngineChoice.auto);
    final ai = await vault.read('ai');
    if (ai != null) {
      try {
        aiConfig = AiConfig.fromJson(jsonDecode(ai)) ?? aiConfig;
      } catch (_) {}
    }
  }

  Future<void> setEngine(EngineChoice e) async {
    engineChoice = e;
    await vault.write('engine', e.name);
    notifyListeners();
  }

  Future<void> setAiConfig(AiConfig c) async {
    aiConfig = c;
    await vault.write('ai', jsonEncode(c.toJson()));
    notifyListeners();
  }

  /// Runs the writing assistant. Nothing in the page changes until the user
  /// approves the result in the floating window.
  Future<String> assist(String instruction, String text) =>
      AssistantClient(aiConfig).run(instruction, text);

  Future<void> setDeeplKey(String? key) async {
    final k = key?.trim();
    _deeplKey = (k == null || k.isEmpty) ? null : k;
    await vault.write('deeplkey', _deeplKey);
    notifyListeners();
  }
  String get deviceName => isDesktop ? Platform.localHostname : 'Phone';
  Directory get dataDir => store.root;

  Future<void> init() async {
    // MIDAD_DATA lets a second, separate library run (used for testing).
    final override = Platform.environment['MIDAD_DATA'];
    final base = override != null ? Directory(override) : await getApplicationSupportDirectory();
    await base.create(recursive: true);
    vault = OsVault(File('${base.path}${Platform.pathSeparator}vault.sealed'));
    identity = await Identity.load(vault);
    fingerprint = await identity.fingerprint();
    store = Store(Directory('${base.path}${Platform.pathSeparator}library'), identity.deviceId);
    await store.open();
    final peers = PeerList(vault);
    await peers.load();
    engine = isDesktop
        ? HostEngine(store, identity, peers, vault, deviceName)
        : ClientEngine(store, identity, peers, vault, deviceName);
    await _loadKeys();
    _prefsFile = File('${base.path}${Platform.pathSeparator}prefs.json');
    await _loadPrefs();
    _subs
      ..add(store.changes.listen((_) => notifyListeners()))
      ..add(engine.statusStream.listen((_) => notifyListeners()))
      ..add(engine.progressStream.listen((_) => notifyListeners()))
      ..add(engine.apiKeyReceived.listen((from) async {
        await _loadKeys();
        _toasts.add('Translation key received from $from');
        notifyListeners();
      }));
    if (engine is HostEngine) {
      _subs.add((engine as HostEngine).pairedStream.listen((n) {
        _toasts.add('Linked with $n');
        notifyListeners();
      }));
    }
    try {
      await engine.start();
    } catch (e) {
      _toasts.add('Could not open the link port: $e');
    }
  }

  /// Test hook: wire the controller without platform channels.
  @visibleForTesting
  Future<void> initForTest(Store st, SyncEngine eng, Vault v, Identity id, Directory base) async {
    store = st;
    engine = eng;
    vault = v;
    identity = id;
    fingerprint = await id.fingerprint();
    _prefsFile = File('${base.path}${Platform.pathSeparator}prefs.json');
  }

  /// Test hook: subscribe to store/engine changes from the caller's zone.
  @visibleForTesting
  void listenForTest() {
    _subs
      ..add(store.changes.listen((_) => notifyListeners()))
      ..add(engine.statusStream.listen((_) => notifyListeners()));
  }

  void toast(String m) => _toasts.add(m);

  Future<void> setApiKey(String? key) async {
    final k = key?.trim();
    _apiKey = (k == null || k.isEmpty) ? null : k;
    await vault.write('apikey', _apiKey);
    notifyListeners();
  }

  /// Sends every saved translation key to the linked device.
  Future<bool> shareApiKey() async {
    var sent = false;
    if (_apiKey != null) sent = await engine.shareApiKey(_apiKey!, kind: 'claude') || sent;
    if (_deeplKey != null) sent = await engine.shareApiKey(_deeplKey!, kind: 'deepl') || sent;
    if (aiConfig.ready) {
      sent = await engine.shareApiKey(jsonEncode(aiConfig.toJson()), kind: 'ai') || sent;
    }
    return sent;
  }

  Future<Session> newSession() async {
    final s = Session.create(identity.deviceId);
    await store.saveLocal(s);
    return s;
  }

  /// Adds files in the background. On Android the picker hands us its own
  /// temporary copy, which is moved (not copied again) into the library.
  Future<void> addFiles(Session s, List<(File, String)> files) async {
    final list = importing.putIfAbsent(s.id, () => []);
    list.addAll(files.map((f) => f.$2));
    notifyListeners();
    try {
      for (final (f, name) in files) {
        try {
          final a = await store.importFile(f, name: name, move: Platform.isAndroid);
          final cur = store.get(s.id) ?? s;
          if (!cur.attachments.any((x) => x.sha == a.sha)) cur.attachments.add(a);
          await store.saveLocal(cur); // each file appears as soon as it is ready
        } catch (e) {
          toast('Could not add $name: $e');
        } finally {
          list.remove(name);
          notifyListeners();
        }
      }
    } finally {
      if (list.isEmpty) importing.remove(s.id);
      notifyListeners();
    }
  }

  /// Saves a copy where the user can find it: Downloads/H11 on the phone,
  /// a "Save as" location on the computer. Returns where it went, or null.
  Future<String?> saveAttachment(Attachment a) async {
    final f = await store.findBlob(a.sha);
    if (f == null) return null;
    if (Platform.isAndroid) {
      return const MethodChannel('midad/keystore')
          .invokeMethod<String>('saveToDownloads', {'path': f.path, 'name': a.name});
    }
    final home = Platform.environment['USERPROFILE'];
    final target = await FilePicker.saveFile(
      dialogTitle: 'Save ${a.name}',
      fileName: a.name,
      initialDirectory: home == null ? null : '$home${Platform.pathSeparator}Downloads',
    );
    if (target == null) return null; // cancelled
    await f.copy(target);
    if (Platform.isWindows) await Process.run('explorer.exe', ['/select,', target]);
    return target;
  }

  Future<void> removeAttachment(Session s, Attachment a) async {
    s.attachments.removeWhere((x) => x.sha == a.sha);
    await store.saveLocal(s);
  }

  /// Translates the page; the result is stored in the session, so it
  /// appears on both devices at once.
  Future<void> translate(Session s) async {
    final text = [s.title.trim(), s.body.trim()].where((e) => e.isNotEmpty).join('\n\n');
    if (text.isEmpty) return;
    translating.add(s.id);
    notifyListeners();
    try {
      final to = targetFor(text);
      final (out, by) = await _service().translate(text, to);
      final current = store.get(s.id) ?? s;
      current.translation = Translation(
          text: out, to: to, sourceHash: await sourceHash(text),
          at: DateTime.now().millisecondsSinceEpoch, by: by);
      await store.saveLocal(current);
    } finally {
      translating.remove(s.id);
      notifyListeners();
    }
  }

  Future<bool> translationIsStale(Session s) async {
    final t = s.translation;
    if (t == null) return false;
    final text = [s.title.trim(), s.body.trim()].where((e) => e.isNotEmpty).join('\n\n');
    return await sourceHash(text) != t.sourceHash;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
