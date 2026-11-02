import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/main.dart' as app;
import 'package:openreader_native/offline_engine.dart';
import 'package:openreader_native/offline_library.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/playback.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_install_test.dart' show prepareOfflineAssets;
import 'test_config.dart';

class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Networking is disabled for offline voice verification.');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('generate uncached voices and read PDFs with networking disabled', (
    tester,
  ) async {
    await prepareOfflineAssets(tester);
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
    expect(
      disconnected,
      isTrue,
      reason: 'The Android device must actually be disconnected.',
    );
    final blocker = _NoNetwork();
    final previous = HttpOverrides.current;
    HttpOverrides.global = blocker;
    addTearDown(() => HttpOverrides.global = previous);
    final preferences = await SharedPreferences.getInstance();
    final store = await OfflineStore.open();
    expect(await store.packInstalled, isTrue);
    final saved = (await store.documents()).firstWhere(
      (document) => document.document['name'] == 'Offline-on-phone-check.pdf',
    );
    final started = DateTime.now();
    final engine = OfflineVoiceEngine(store);
    final novel =
        'A brand new natural voice sample generated on this phone, number ${started.millisecondsSinceEpoch}.';
    final michael = await engine.synthesize(novel, 'am_michael');
    final fenrir = await engine.synthesize(novel, 'am_fenrir');
    expect(michael.durationMs, greaterThan(1000));
    expect(fenrir.durationMs, greaterThan(1000));
    final a = await File(michael.path).readAsBytes();
    final b = await File(fenrir.path).readAsBytes();
    expect(String.fromCharCodes(a.take(4)), 'RIFF');
    expect(sha256.convert(a).toString(), isNot(sha256.convert(b).toString()));
    final pcm = ByteData.sublistView(a, 44);
    var peak = 0;
    for (var i = 0; i < pcm.lengthInBytes; i += 2) {
      final sample = pcm.getInt16(i, Endian.little).abs();
      if (sample > peak) peak = sample;
    }
    expect(peak, greaterThan(500));
    expect(
      (await File(
        michael.path,
      ).stat()).modified.isBefore(started.subtract(const Duration(seconds: 2))),
      isFalse,
    );
    expect(blocker.attempts, 0);
    await engine.close();
    debugPrint(
      'Michael and Fenrir synthesized distinct non-silent uncached WAV audio with zero network access.',
    );

    await tester.pumpWidget(
      MaterialApp(home: OfflineLibraryPage(preferences: preferences)),
    );
    Future<void> waitFor(bool Function() condition, [int seconds = 180]) async {
      for (var i = 0; i < seconds * 4; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (condition()) return;
      }
      fail('Timed out waiting for offline reader state');
    }

    final entry = find.byKey(Key('offline-document-${saved.key}'));
    await waitFor(() => entry.evaluate().isNotEmpty);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    ReaderPlayback? reader;
    await waitFor(() {
      for (final element in find.byType(AnimatedBuilder).evaluate()) {
        final builder = element.widget as AnimatedBuilder;
        if (builder.animation is ReaderPlayback) {
          reader = builder.animation as ReaderPlayback;
          if (reader!.error != null) fail(reader!.error!);
          return reader!.connected &&
              find.byType(PdfViewer).evaluate().isNotEmpty;
        }
      }
      return false;
    });
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    await waitFor(() => viewer.isReady);
    expect(viewer.pageCount, 2);
    expect(reader!.isOffline, isTrue);
    final passage = reader!.plan.firstWhere(
      (row) => (row['text'] as String).length > 120,
    );
    await reader!.selectAt(integer(passage['ordinal']));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('play-pause')));
    await waitFor(() {
      if (reader!.error != null) fail(reader!.error!);
      return !reader!.preparing &&
          reader!.player.position.inMilliseconds > 1200 &&
          reader!.activeWord != null;
    });
    expect(reader!.voice, contains('Michael'));
    final element = find.byType(PdfViewer).evaluate().single;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PdfViewer).evaluate().single, same(element));
    expect(reader!.wantedPlaying, isTrue);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(950, 1000);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PdfViewer).evaluate().single, same(element));
    await waitFor(() {
      if (reader!.error != null) fail(reader!.error!);
      return reader!.currentOrdinal > integer(passage['ordinal']) &&
          !reader!.preparing &&
          reader!.player.position.inMilliseconds > 400;
    });
    await tester.tap(find.byKey(const Key('play-pause')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(reader!.wantedPlaying, isFalse);
    await reader!.setOfflineVoice('am_fenrir');
    await tester.tap(find.byKey(const Key('play-pause')));
    await waitFor(() {
      if (reader!.error != null) fail(reader!.error!);
      return !reader!.preparing && reader!.player.position.inMilliseconds > 600;
    });
    expect(reader!.voice, contains('Fenrir'));
    expect(blocker.attempts, 0);
    await tester.tap(find.byKey(const Key('play-pause')));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugPrint(
      'Saved PDF rendered and continuous on-phone narration, word-following, folding and voice switching worked without network requests.',
    );

    app.main();
    await tester.pump(const Duration(seconds: 2));
    final baseline = blocker.attempts;
    await tester.tap(find.byKey(const Key('open-offline-library')));
    await waitFor(() => entry.evaluate().isNotEmpty);
    expect(blocker.attempts, baseline);
    expect(find.text('Offline library'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    debugPrint(
      'Offline library reopens from app startup with no server login required.',
    );
  }, timeout: const Timeout(Duration(minutes: 12)));
}
