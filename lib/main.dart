import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/controller.dart';
import 'ui/home.dart';
import 'ui/motion.dart';
import 'ui/theme.dart';
import 'ui/window_frame.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final startHidden = args.contains('--hidden');

  if (isDesktop) {
    await windowManager.ensureInitialized();
    final dark = _isDark();
    final pal = dark ? Palette.dark : Palette.light;
    final opts = WindowOptions(
      size: Size(430, 700), // small, like a pocket notebook
      minimumSize: Size(360, 480),
      center: true,
      title: 'H11',
      backgroundColor: pal.paper,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await matchWindowFrame(dark: dark, paper: pal.paper, ink: pal.ink, rule: pal.rule);
      if (!startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
  }

  final app = AppController();
  await app.init();
  if (isDesktop) await _Desktop.setup();
  runApp(H11App(app: app));
}

/// The theme in use: MIDAD_THEME if set, otherwise the system's.
bool _isDark() => switch (Platform.environment['MIDAD_THEME']) {
      'light' => false,
      'dark' => true,
      _ => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
    };

class H11App extends StatefulWidget {
  final AppController app;
  const H11App({super.key, required this.app});
  @override
  State<H11App> createState() => _H11AppState();
}

class _H11AppState extends State<H11App> with WidgetsBindingObserver {
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Windows switched light/dark: repaint the title bar to match.
  @override
  void didChangePlatformBrightness() {
    if (!isDesktop) return;
    final dark = _isDark();
    final pal = dark ? Palette.dark : Palette.light;
    matchWindowFrame(dark: dark, paper: pal.paper, ink: pal.ink, rule: pal.rule);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'H11',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: switch (Platform.environment['MIDAD_THEME']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: LaunchIntro(child: Home(app: app, desktopBar: isDesktop ? const _PinButton() : null)),
    );
  }
}

/// Windows behaviour: lives in the tray so the link stays up, opens with
/// Ctrl+Alt+M from anywhere, closes to the tray instead of quitting.
class _Desktop with WindowListener, TrayListener {
  static final _i = _Desktop();

  static Future<void> setup() async {
    await windowManager.setPreventClose(true);
    windowManager.addListener(_i);
    trayManager.addListener(_i);
    try {
      // Today's color: the tray and the taskbar icon match the in-app mark.
      final i = Launch.colorIndex;
      await trayManager.setIcon(
          Platform.isWindows ? 'assets/icon/tray_$i.ico' : 'assets/icon/icon_512.png');
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        await windowManager.setIcon('$exeDir/data/flutter_assets/assets/icon/app_$i.ico');
      }
      await trayManager.setToolTip('H11');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Open H11    Ctrl+Alt+M'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit (stops syncing)'),
      ]));
    } catch (_) {}
    try {
      await hotKeyManager.unregisterAll();
      await hotKeyManager.register(
        HotKey(
          key: PhysicalKeyboardKey.keyM,
          modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
          scope: HotKeyScope.system,
        ),
        keyDownHandler: (_) => toggle(),
      );
    } catch (_) {}
  }

  static Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> toggle() async {
    if (await windowManager.isVisible() && await windowManager.isFocused()) {
      await windowManager.hide();
    } else {
      await show();
    }
  }

  @override
  void onWindowClose() => windowManager.hide();

  @override
  void onTrayIconMouseDown() => show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'open') show();
    if (item.key == 'quit') {
      await hotKeyManager.unregisterAll();
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      exit(0);
    }
  }
}

class _PinButton extends StatefulWidget {
  const _PinButton();
  @override
  State<_PinButton> createState() => _PinButtonState();
}

class _PinButtonState extends State<_PinButton> {
  bool _on = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Keep H11 above other windows',
      child: InkButton(_on ? 'Pinned' : 'Pin', accent: _on, onTap: () async {
        _on = !_on;
        await windowManager.setAlwaysOnTop(_on);
        setState(() {});
      }),
    );
  }
}
