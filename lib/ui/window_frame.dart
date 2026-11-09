// Makes the Windows title bar and the window's own background match the
// app's paper colour, so there is no grey bar on top and no white edge or
// flash behind the page in dark mode.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:window_manager/window_manager.dart';

typedef _FindC = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindD = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _SetC = Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Uint32);
typedef _SetD = int Function(int, int, Pointer<Uint32>, int);

const _darkMode = 20; // DWMWA_USE_IMMERSIVE_DARK_MODE
const _borderColor = 34; // DWMWA_BORDER_COLOR (Windows 11)
const _captionColor = 35; // DWMWA_CAPTION_COLOR (Windows 11)
const _textColor = 36; // DWMWA_TEXT_COLOR (Windows 11)

int _colorRef(Color c) {
  final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
  return (b << 16) | (g << 8) | r; // COLORREF is 0x00BBGGRR
}

/// Paints the frame: title bar, title text, 1px border and window background.
Future<void> matchWindowFrame({required bool dark, required Color paper, required Color ink, required Color rule}) async {
  if (!Platform.isWindows) return;
  try {
    await windowManager.setBackgroundColor(paper);
  } catch (_) {}
  try {
    final user = DynamicLibrary.open('user32.dll');
    final dwm = DynamicLibrary.open('dwmapi.dll');
    final find = user.lookupFunction<_FindC, _FindD>('FindWindowW');
    final set = dwm.lookupFunction<_SetC, _SetD>('DwmSetWindowAttribute');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final title = 'H11'.toNativeUtf16();
    final hwnd = find(cls, title);
    calloc
      ..free(cls)
      ..free(title);
    if (hwnd == 0) return;
    final v = calloc<Uint32>();
    void put(int attr, int value) {
      v.value = value;
      set(hwnd, attr, v, 4); // older Windows 10 simply ignores 34-36
    }

    put(_darkMode, dark ? 1 : 0);
    put(_captionColor, _colorRef(paper));
    put(_textColor, _colorRef(ink));
    put(_borderColor, _colorRef(rule));
    calloc.free(v);
  } catch (_) {}
}
