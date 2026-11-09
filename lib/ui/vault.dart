import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../core/identity.dart';

/// Secrets file sealed by the operating system:
///  - Windows: DPAPI (bound to this Windows user account)
///  - Android: AES-256-GCM key held inside the Android Keystore
class OsVault implements Vault {
  final File file;
  Map<String, String>? _cache;
  OsVault(this.file);

  static const _ch = MethodChannel('midad/keystore');

  Future<Uint8List> _seal(Uint8List p) async =>
      Platform.isWindows ? _Dpapi.protect(p) : (await _ch.invokeMethod<Uint8List>('seal', p))!;

  Future<Uint8List> _open(Uint8List c) async =>
      Platform.isWindows ? _Dpapi.unprotect(c) : (await _ch.invokeMethod<Uint8List>('open', c))!;

  Future<Map<String, String>> _all() async {
    if (_cache != null) return _cache!;
    if (!await file.exists()) return _cache = {};
    final plain = await _open(await file.readAsBytes());
    final m = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return _cache = m.map((k, v) => MapEntry(k, v as String));
  }

  @override
  Future<String?> read(String key) async => (await _all())[key];

  @override
  Future<void> write(String key, String? value) async {
    final m = await _all();
    value == null ? m.remove(key) : m[key] = value;
    final sealed = await _seal(Uint8List.fromList(utf8.encode(jsonEncode(m))));
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(file.path);
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptC = Int32 Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>,
    Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptD = int Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>,
    Pointer<Void>, int, Pointer<_Blob>);
typedef _UnC = Int32 Function(Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>,
    Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _UnD = int Function(Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>,
    Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);

class _Dpapi {
  static final _crypt = DynamicLibrary.open('crypt32.dll');
  static final _k32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt.lookupFunction<_CryptC, _CryptD>('CryptProtectData');
  static final _unprotect = _crypt.lookupFunction<_UnC, _UnD>('CryptUnprotectData');
  static final _localFree =
      _k32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
          'LocalFree');
  static const _uiForbidden = 0x1;
  // Extra entropy so other apps of the same user cannot trivially reuse the blob.
  static final _entropy = utf8.encode('midad.vault.v1');

  static Uint8List _run(Uint8List data, bool protect) {
    return using((arena) {
      final inB = arena<_Blob>();
      final ent = arena<_Blob>();
      final out = arena<_Blob>();
      final buf = arena<Uint8>(data.isEmpty ? 1 : data.length);
      buf.asTypedList(data.length).setAll(0, data);
      inB.ref
        ..cbData = data.length
        ..pbData = buf;
      final e = arena<Uint8>(_entropy.length);
      e.asTypedList(_entropy.length).setAll(0, _entropy);
      ent.ref
        ..cbData = _entropy.length
        ..pbData = e;
      final ok = protect
          ? _protect(inB, 'H11'.toNativeUtf16(allocator: arena), ent, nullptr, nullptr,
              _uiForbidden, out)
          : _unprotect(inB, nullptr, ent, nullptr, nullptr, _uiForbidden, out);
      if (ok == 0) throw StateError('DPAPI failed');
      final result = Uint8List.fromList(out.ref.pbData.asTypedList(out.ref.cbData));
      _localFree(out.ref.pbData.cast());
      return result;
    });
  }

  static Uint8List protect(Uint8List d) => _run(d, true);
  static Uint8List unprotect(Uint8List d) => _run(d, false);
}
