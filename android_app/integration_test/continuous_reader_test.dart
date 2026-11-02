import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/main.dart';
import 'package:openreader_native/offline_library.dart';
import 'package:openreader_native/offline_narration.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/playback.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_install_test.dart' show prepareOfflineAssets;
import 'test_config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'complete saved narration, PDF words, source switch and public demo',
    (tester) async {
      await prepareOfflineAssets(tester);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble('offlinePlaybackSpeed', .9);
      await preferences.setDouble('serverPlaybackSpeed', 1.1);
      await preferences.setBool('pdfDarkMode', true);
      final server = OpenReaderApi(Uri.parse(testServer));
      await server.signIn(
        testEmail,
        const String.fromEnvironment('TEST_PASSWORD'),
      );
      server.close();
      final store = await OfflineStore.open();
      final imported = (await store.documents()).firstWhere(
        (doc) => doc.document['name'] == 'Offline-on-phone-check.pdf',
      );
      final document = await store.save(
        origin: imported.origin,
        account: 'local',
        document: {...imported.document, 'name': 'Reading room demo.pdf'},
        payload: imported.payload,
        bytes: await imported.pdf.readAsBytes(),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('public-demo-capture'),
          child: const OpenReaderApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => OfflineLibraryPage(preferences: preferences),
          ),
        ),
      );
      Future<void> waitFor(
        bool Function() condition, [
        int seconds = 180,
      ]) async {
        for (var i = 0; i < seconds * 4; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (condition()) return;
        }
        fail('Timed out waiting for continuous-reader state');
      }

      final entry = find.byKey(Key('offline-document-${document.key}'));
      await waitFor(() => entry.evaluate().isNotEmpty);
      await tester.ensureVisible(entry);
      await tester.tap(find.byKey(Key('offline-options-${document.key}')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Prepare entire PDF audio'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('start-prepare-audio')));
      final book = SavedNarration(document, 'am_michael');
      var status = await book.progress();
      for (var i = 0; i < 720 && status.completed < 2; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        status = await book.progress();
      }
      expect(status.completed, greaterThanOrEqualTo(2));
      await tester.tap(find.widgetWithText(TextButton, 'Stop'));
      await waitFor(
        () => find.widgetWithText(FilledButton, 'Resume').evaluate().isNotEmpty,
      );
      expect((await book.progress()).complete, isFalse);
      await tester.tap(find.byKey(const Key('start-prepare-audio')));
      await waitFor(
        () => find
            .text('All audio saved / ready for continuous playback')
            .evaluate()
            .isNotEmpty,
        420,
      );
      await waitFor(
        () => find.widgetWithText(TextButton, 'Close').evaluate().isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pump(const Duration(seconds: 1));
      expect((await book.progress()).complete, isTrue);
      await store.pack.delete(recursive: true);
      if (await store.audio.exists()) await store.audio.delete(recursive: true);
      debugPrint('OFFLINE_READY_FOR_AIRPLANE');
      await Future<void>.delayed(const Duration(seconds: 4));
      var disconnected = false;
      try {
        final socket = await Socket.connect(
          Uri.parse(testServer).host,
          3005,
          timeout: const Duration(seconds: 3),
        );
        socket.destroy();
      } on SocketException {
        disconnected = true;
      }
      expect(disconnected, isTrue);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      ReaderPlayback? reader;
      await waitFor(() {
        for (final element in find.byType(AnimatedBuilder).evaluate()) {
          final animation = (element.widget as AnimatedBuilder).animation;
          if (animation is ReaderPlayback) {
            reader = animation;
            if (reader!.error != null) fail(reader!.error!);
            return reader!.connected &&
                find.byType(PdfViewer).evaluate().isNotEmpty;
          }
        }
        return false;
      });
      final original = find.byType(PdfViewer).evaluate().single;
      final player = reader!.player;
      await tester.tap(find.byKey(const Key('play-pause')));
      final passed = <int>{};
      var preparationReturns = 0;
      var began = false;
      await waitFor(() {
        if (reader!.error != null) fail(reader!.error!);
        if (!reader!.preparing && player.playing) {
          began = true;
          passed.add(reader!.currentOrdinal);
        }
        if (began && reader!.preparing) preparationReturns++;
        return passed.length >= 2 &&
            player.position.inMilliseconds > 700 &&
            find.byKey(const Key('pdf-spoken-word')).evaluate().isNotEmpty;
      });
      expect(preparationReturns, 0);
      expect(reader!.speed, .9);
      expect(await store.packInstalled, isFalse);
      await tester.tap(find.byKey(const Key('play-pause')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('pdf-spoken-word')), findsOneWidget);

      Future<void> screenshot(String name, Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Reading room demo.pdf'), findsOneWidget);
        expect(find.byType(PdfViewer).evaluate().single, same(original));
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('public-demo-capture')),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File('${(await getTemporaryDirectory()).path}/$name')
              .writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      }

      await screenshot('reader-dark.png', const Size(950, 1000));
      await screenshot('reader-phone.png', const Size(390, 844));
      debugPrint('PUBLIC_SCREENSHOTS_READY');
      await Future<void>.delayed(const Duration(seconds: 3));
      debugPrint(
        'Prepared audio played across paragraphs with no model or generation pause; real PDF words painted.',
      );
      debugPrint('RESTORE_NETWORK_FOR_SWITCH');
      await Future<void>.delayed(const Duration(seconds: 6));
      await tester.tap(find.byKey(const Key('voice-source')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Server').last);
      await waitFor(
        () => find
            .widgetWithText(FilledButton, 'Upload copy')
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Upload copy'));
      await waitFor(() {
        for (final element in find.byType(AnimatedBuilder).evaluate()) {
          final animation = (element.widget as AnimatedBuilder).animation;
          if (animation is ReaderPlayback &&
              !animation.isOffline &&
              animation.connected) {
            reader = animation;
            return true;
          }
        }
        return false;
      }, 240);
      expect(find.byType(PdfViewer).evaluate().single, same(original));
      expect(reader!.speed, 1.1);
      await tester.tap(find.byKey(const Key('play-pause')));
      await waitFor(() {
        if (reader!.error != null) fail(reader!.error!);
        return !reader!.preparing &&
            reader!.player.position.inMilliseconds > 500;
      });
      await tester.tap(find.byKey(const Key('voice-source')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Phone / offline').last);
      await waitFor(() {
        for (final element in find.byType(AnimatedBuilder).evaluate()) {
          final animation = (element.widget as AnimatedBuilder).animation;
          if (animation is ReaderPlayback &&
              animation.isOffline &&
              animation.connected &&
              !animation.preparing) {
            reader = animation;
            return true;
          }
        }
        return false;
      });
      expect(reader!.speed, .9);
      expect(reader!.wantedPlaying, isTrue);
      expect(find.byType(PdfViewer).evaluate().single, same(original));
      debugPrint(
        'Server/phone switching retained the PDF, consented upload and independent pace.',
      );
      debugPrint('SYNTHETIC_SERVER_DOCUMENT_ID=${document.document['id']}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
