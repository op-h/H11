// Interface tests at real phone and computer sizes.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midad/core/identity.dart';
import 'package:midad/core/model.dart';
import 'package:midad/core/store.dart';
import 'package:midad/core/sync.dart';
import 'package:midad/ui/controller.dart';
import 'package:midad/ui/home.dart';
import 'package:midad/ui/page.dart';
import 'package:midad/ui/theme.dart';

/// Galaxy S23+ is 1080 px wide at ~2.81 density = 384 logical px.
const phone = Size(384, 832);
const smallPhone = Size(320, 640);
const pc = Size(430, 700);

late Directory _dir;

Future<AppController> makeApp(WidgetTester t, {int pages = 0, String body = 'hello'}) async {
  final app = (await t.runAsync(() async {
    _dir = await Directory.systemTemp.createTemp('h11_ui');
    final v = FileVault(File('${_dir.path}/v.json'));
    final id = await Identity.load(v);
    final st = Store(Directory('${_dir.path}/lib'), id.deviceId);
    await st.open();
    final peers = PeerList(v);
    final eng = ClientEngine(st, id, peers, v, 'Phone');
    final app = AppController();
    await app.initForTest(st, eng, v, id, _dir);
    for (var i = 0; i < pages; i++) {
      final s = Session.create(id.deviceId)
        ..title = 'Page number $i with a fairly long title'
        ..body = body;
      await st.saveLocal(s);
    }
    return app;
  }))!;
  app.listenForTest(); // in the widget-test zone, like the real app
  return app;
}

Widget wrap(Widget w, {Brightness b = Brightness.light}) =>
    MaterialApp(theme: buildTheme(b), home: w, debugShowCheckedModeBanner: false);

Future<void> setSize(WidgetTester t, Size s) async {
  t.view.physicalSize = s * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final (name, size) in [('S23+', phone), ('small phone', smallPhone), ('computer window', pc)]) {
    for (final b in Brightness.values) {
      testWidgets('page toolbar fits on $name (${b.name}): no overflow, every action reachable', (t) async {
        await setSize(t, size);
        final app = await makeApp(t, pages: 1, body: 'سطر عربي\nEnglish line');
        final id = app.store.sorted().first.id;
        await t.pumpWidget(wrap(PageScreen(app: app, id: id, standalone: true), b: b));
        await settle(t);
        expect(t.takeException(), isNull, reason: 'no layout overflow');
        expect(find.text('More'), findsOneWidget);
        expect(t.getRect(find.text('More')).right, lessThanOrEqualTo(size.width),
            reason: 'More is always on screen');
        // Scroll the toolbar to reach the last action.
        final translate = find.textContaining('Translate');
        await t.dragUntilVisible(translate, find.byType(SingleChildScrollView).last, const Offset(-80, 0));
        await settle(t);
        expect(t.getRect(translate).right, lessThanOrEqualTo(size.width));
        expect(find.text('Attach'), findsOneWidget);
        expect(find.text('Assist'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        await settle(t);
      });
    }
  }

  testWidgets('swipe to delete asks first; Keep keeps, Delete deletes', (t) async {
    await setSize(t, phone);
    final app = await makeApp(t, pages: 3);
    var notes = 0;
    app.addListener(() => notes++);
    await t.pumpWidget(wrap(Home(app: app)));
    await settle(t);
    expect(find.textContaining('Page number'), findsNWidgets(3));

    await t.drag(find.textContaining('Page number 2'), const Offset(-300, 0));
    await settle(t);
    expect(find.text('Delete this page?'), findsOneWidget);
    expect(find.text('Here only'), findsOneWidget);
    expect(find.text('Both devices'), findsOneWidget);
    await t.tap(find.text('Keep'));
    await settle(t);
    expect(find.textContaining('Page number'), findsNWidgets(3));

    await t.drag(find.textContaining('Page number 2'), const Offset(300, 0)); // other direction
    await settle(t);

    await t.tap(find.text('Here only'));
    // File deletion is real disk I/O: give it real time to finish.
    final before = notes;
    for (var i = 0; i < 30 && notes == before; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 50));
    }
    await settle(t);
    expect(find.textContaining('Page number'), findsNWidgets(2));
    expect(app.store.tombstones.length, 1);
    await t.pumpWidget(const SizedBox());
    await settle(t);
  });

  testWidgets('index with long Arabic and English titles: no overflow on a small phone', (t) async {
    await setSize(t, smallPhone);
    final app = await makeApp(t, pages: 8, body: 'نص طويل جداً ' * 40);
    await t.pumpWidget(wrap(Home(app: app), b: Brightness.dark));
    await settle(t);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await settle(t);
  });

  testWidgets('empty library shows the welcome and a working Start button', (t) async {
    await setSize(t, phone);
    final app = await makeApp(t);
    await t.pumpWidget(wrap(Home(app: app)));
    await settle(t);
    expect(find.text('A blank page.'), findsOneWidget);
    await t.tap(find.text('Start writing'));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 200)));
    await settle(t);
    expect(app.store.sessions.length, 1);
    await t.pumpWidget(const SizedBox());
    await settle(t);
  });

  for (final size in [phone, pc]) {
    testWidgets('translation Hide/Show works on ${size == phone ? 'the phone' : 'the computer'}', (t) async {
      await setSize(t, size);
      final app = await makeApp(t);
      final id = (await t.runAsync(() async {
        final s = Session.create(app.identity.deviceId)
          ..body = 'Good morning'
          ..translation = const Translation(
              text: 'صباح الخير\nسطر ثان', to: 'ar', sourceHash: 'x', at: 1, by: 'Google');
        await app.store.saveLocal(s);
        return s.id;
      }))!;
      await t.pumpWidget(wrap(PageScreen(app: app, id: id, standalone: true)));
      await settle(t);
      await t.scrollUntilVisible(find.text('Hide'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('صباح الخير\nسطر ثان'), findsOneWidget, reason: 'full translation shown');

      await t.tap(find.text('Hide'));
      await settle(t);
      expect(find.text('Show'), findsOneWidget);
      expect(find.text('صباح الخير\nسطر ثان'), findsNothing, reason: 'full text folded away');
      expect(find.text('صباح الخير'), findsOneWidget, reason: 'one-line preview stays');
      expect(app.translationHidden(id), isTrue);

      await t.tap(find.text('Show'));
      await settle(t);
      expect(find.text('صباح الخير\nسطر ثان'), findsOneWidget);
      expect(app.translationHidden(id), isFalse);

      // Tapping the header bar itself also folds it.
      await t.tap(find.textContaining('English → Arabic', findRichText: true));
      await settle(t);
      expect(app.translationHidden(id), isTrue);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle(t);
    });
  }

  testWidgets('"hide translations by default" hides them until you open one', (t) async {
    await setSize(t, phone);
    final app = await makeApp(t);
    final id = (await t.runAsync(() async {
      final s = Session.create(app.identity.deviceId)
        ..body = 'Hi'
        ..translation = const Translation(text: 'مرحبا', to: 'ar', sourceHash: 'x', at: 1);
      await app.store.saveLocal(s);
      await app.setHideTranslationsByDefault(true);
      return s.id;
    }))!;
    expect(app.translationHidden(id), isTrue);
    await t.pumpWidget(wrap(PageScreen(app: app, id: id, standalone: true)));
    await settle(t);
    await t.scrollUntilVisible(find.text('Show'), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Show'));
    await settle(t);
    expect(app.translationHidden(id), isFalse);
    await t.pumpWidget(const SizedBox());
    await settle(t);
  });

  testWidgets('assistant window opens over the page and closes', (t) async {
    await setSize(t, phone);
    final app = await makeApp(t, pages: 1);
    final id = app.store.sorted().first.id;
    await t.pumpWidget(wrap(PageScreen(app: app, id: id, standalone: true)));
    await settle(t);
    await t.tap(find.text('Assist'));
    await settle(t);
    expect(find.text('Assistant'), findsOneWidget);
    expect(find.text('Improve'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.text('Close'));
    await settle(t);
    expect(find.text('Assistant'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await settle(t);
  });
}
