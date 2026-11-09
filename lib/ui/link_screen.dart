import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/identity.dart';
import '../core/sync.dart';
import 'controller.dart';
import 'theme.dart';

class LinkScreen extends StatefulWidget {
  final AppController app;
  const LinkScreen({super.key, required this.app});
  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  PairingOffer? _offer;
  Timer? _tick;
  String? _peerFp;
  bool _pairing = false;
  String? _error;

  AppController get app => widget.app;
  bool get _host => app.engine is HostEngine;

  @override
  void initState() {
    super.initState();
    app.addListener(_refresh);
    _loadPeerFp();
  }

  void _refresh() {
    if (mounted) setState(() {});
    // A phone just paired: close the code.
    if (_offer != null && app.engine.status.state == LinkState.connected) _stopOffer();
  }

  Future<void> _loadPeerFp() async {
    if (_host) return;
    final pc = (app.engine as ClientEngine).computer;
    _peerFp = pc == null ? null : await fingerprintOf(unhex(pc.pub));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    app.removeListener(_refresh);
    _tick?.cancel();
    if (_host) (app.engine as HostEngine).cancelPairing();
    super.dispose();
  }

  Future<void> _startOffer() async {
    final o = await (app.engine as HostEngine).beginPairing();
    setState(() => _offer = o);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_offer != null && DateTime.now().isAfter(_offer!.expires)) _stopOffer();
      if (mounted) setState(() {});
    });
  }

  void _stopOffer() {
    _tick?.cancel();
    (app.engine as HostEngine).cancelPairing();
    if (mounted) setState(() => _offer = null);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _Scanner(), fullscreenDialog: true));
    if (code == null) return;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final name = await (app.engine as ClientEngine).pair(code);
      app.toast('Linked with $name');
      await _loadPeerFp();
    } catch (e) {
      setState(() => _error = 'Could not link. Make sure both devices are on the same Wi-Fi, '
          'the code is still showing on the computer, and Windows Firewall allows H11 '
          'on private networks.');
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
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
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _host ? _hostView(c) : _phoneView(c),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _hostView(Palette c) {
    final host = app.engine as HostEngine;
    final left = _offer?.expires.difference(DateTime.now());
    return [
      Text('Link your phone', style: T.title(c, size: 28)),
      const SizedBox(height: 10),
      Text('The link is end-to-end encrypted and works over your own Wi-Fi. '
          'Nothing passes through any server.',
          style: T.ui(c, size: 14.5, color: c.pencil).copyWith(height: 1.55)),
      const SizedBox(height: 28),
      if (_offer == null) ...[
        _Step('1', 'Open H11 on your phone and tap the status line under the title.'),
        _Step('2', 'Tap “Scan the code”, then point it at this screen.'),
        const SizedBox(height: 18),
        BlockButton('Show the code', onTap: _startOffer),
      ] else ...[
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: c.rule),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Center(
            child: QrImageView(
              data: _offer!.code,
              size: 240,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0F1A2E)),
              dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0F1A2E)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Text(
              'Single use · expires in ${left!.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
              style: T.meta(c)),
          const Spacer(),
          InkButton('Hide', onTap: _stopOffer),
        ]),
      ],
      const SizedBox(height: 36),
      Text('LINKED PHONES', style: T.label(c)),
      const SizedBox(height: 8),
      const Hairline(),
      if (host.peers.items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text('None yet.', style: T.ui(c, color: c.faint)),
        ),
      for (final p in host.peers.items)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.rule))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: T.ui(c, w: FontWeight.w500)),
                const SizedBox(height: 2),
                FutureBuilder(
                  future: fingerprintOf(unhex(p.pub)),
                  builder: (_, f) => Text(
                      '${f.data ?? ''}${host.links.any((l) => l.peer.pub == p.pub) ? '  ·  connected' : ''}',
                      style: T.meta(c)),
                ),
              ]),
            ),
            InkButton('Unlink', danger: true, onTap: () => host.removePeer(p.pub)),
          ]),
        ),
      const SizedBox(height: 28),
      Text('This computer’s key  ${app.fingerprint}', style: T.meta(c)),
    ];
  }

  List<Widget> _phoneView(Palette c) {
    final eng = app.engine as ClientEngine;
    final pc = eng.computer;
    final st = eng.status.state;
    return [
      Text(pc == null ? 'Link to your computer' : 'Linked computer', style: T.title(c, size: 28)),
      const SizedBox(height: 10),
      Text(
          'End-to-end encrypted over your own Wi-Fi. Nothing passes through any server. '
          'Pages you write while apart are sent the next time both are open.',
          style: T.ui(c, size: 14.5, color: c.pencil).copyWith(height: 1.55)),
      const SizedBox(height: 28),
      if (pc == null) ...[
        _Step('1', 'On the computer, open H11 → the status line → “Show the code”.'),
        _Step('2', 'Scan it here.'),
        const SizedBox(height: 18),
        BlockButton(_pairing ? 'Linking…' : 'Scan the code', onTap: _pairing ? null : _scan),
      ] else ...[
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.rule), bottom: BorderSide(color: c.rule))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(pc.name, style: T.ui(c, size: 15, w: FontWeight.w500)),
                const SizedBox(height: 3),
                Text(
                    st == LinkState.connected
                        ? 'connected · ${pc.host}'
                        : 'not reachable right now — will retry',
                    style: T.meta(c).copyWith(color: st == LinkState.connected ? c.linked : null)),
                const SizedBox(height: 3),
                Text('key ${_peerFp ?? ''}', style: T.meta(c)),
              ]),
            ),
            InkButton('Retry', onTap: eng.poke),
          ]),
        ),
        const SizedBox(height: 18),
        InkButton('Unlink this phone', danger: true, onTap: () async {
          await eng.unpair();
          setState(() => _peerFp = null);
        }),
      ],
      if (_error != null) ...[
        const SizedBox(height: 18),
        Text(_error!, style: T.ui(c, size: 13.5, color: c.danger).copyWith(height: 1.5)),
      ],
      const SizedBox(height: 28),
      Text('This phone’s key  ${app.fingerprint}', style: T.meta(c)),
    ];
  }
}

class _Step extends StatelessWidget {
  final String n;
  final String text;
  const _Step(this.n, this.text);
  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 26,
            child: Text(n, style: T.title(c, size: 17).copyWith(color: c.accent))),
        Expanded(child: Text(text, style: T.ui(c, size: 14.5).copyWith(height: 1.5))),
      ]),
    );
  }
}

class _Scanner extends StatefulWidget {
  const _Scanner();
  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  bool _done = false;
  final _ctrl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ink;
    return Scaffold(
      backgroundColor: const Color(0xFF0D1220),
      body: Stack(children: [
        MobileScanner(
          controller: _ctrl,
          onDetect: (cap) {
            if (_done) return;
            for (final b in cap.barcodes) {
              final v = b.rawValue;
              if (v != null && v.startsWith('midad:1:')) {
                _done = true;
                Navigator.of(context).pop(v);
                return;
              }
            }
          },
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(border: Border.all(color: c.accent, width: 1.5)),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel',
                    style: TextStyle(color: Color(0xFFE9EDF5), fontFamily: sans, fontSize: 15)),
              ),
            ]),
          ),
        ),
        const Align(
          alignment: Alignment(0, .62),
          child: Text('Point at the code on your computer',
              style: TextStyle(color: Color(0xFFE9EDF5), fontFamily: sans, fontSize: 14)),
        ),
      ]),
    );
  }
}
