import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/alignment.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/main.dart' as app;
import 'package:openreader_native/playback.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native login, PDF, speech, passage following and foldable layouts',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await configureServer(preferences);
      const id =
          '9da559e0436ba73f26ad73a3c23db6c44c6b51c544597843f5ea148d8f08cba7';
      await preferences.setInt('progress:$testServer:$id', 0);
      await preferences.setInt('resume:$testServer:$id', 0);
      app.main();
      await tester.pumpAndSettle();
      if (find.byKey(const Key('password')).evaluate().isNotEmpty) {
        await tester.enterText(
          find.byKey(const Key('password')),
          const String.fromEnvironment('TEST_PASSWORD'),
        );
        await tester.tap(find.byKey(const Key('connect')));
      }
      Future<void> waitFor(
        bool Function() condition, [
        int seconds = 120,
      ]) async {
        for (var i = 0; i < seconds * 2; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (condition()) return;
        }
        fail('Timed out waiting for native reader state');
      }

      final document = find.byKey(
        const Key(
          'document-9da559e0436ba73f26ad73a3c23db6c44c6b51c544597843f5ea148d8f08cba7',
        ),
      );
      await waitFor(() => document.evaluate().isNotEmpty);
      await tester.tap(document);
      await waitFor(() => find.byType(PdfViewer).evaluate().isNotEmpty);
      expect(find.byType(PdfViewer), findsOneWidget);

      ReaderPlayback? playback;
      await waitFor(() {
        for (final element in find.byType(AnimatedBuilder).evaluate()) {
          final widget = element.widget as AnimatedBuilder;
          if (widget.animation is ReaderPlayback) {
            playback = widget.animation as ReaderPlayback;
            return playback!.connected;
          }
        }
        return false;
      });
      final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
      await waitFor(() => viewer.controller!.isReady);
      final nativeText = await viewer.controller!.pages.first.loadText();
      expect(nativeText, isNotNull);
      await tester.tap(find.byKey(const Key('play-pause')));
      final words = <String>{};
      final passages = <int>{};
      var nativeWordMatches = 0;
      await waitFor(() {
        if (playback!.error != null) fail(playback!.error!);
        if (playback!.status == 'Finished' && passages.length < 2) {
          fail('Narration ended without advancing through the PDF passages.');
        }
        if (playback!.wantedPlaying && !playback!.preparing) {
          passages.add(playback!.currentOrdinal);
        }
        final word = playback!.activeWord;
        if (word != null) {
          words.add('${word.ordinal}:${word.wordIndex}');
          final segment = playback!.plan.firstWhere(
            (segment) => integer(segment['ordinal']) == word.ordinal,
          );
          if (findWordRange(
                nativeText!.fullText,
                segment['text'] as String,
                word,
              ) !=
              null) {
            nativeWordMatches++;
          }
        }
        return playback!.player.position.inMilliseconds > 3000 &&
            passages.length >= 2 &&
            words.length >= 4 &&
            nativeWordMatches >= 4;
      }, 240);
      expect(playback!.error, isNull);
      expect(passages.length, greaterThanOrEqualTo(2));
      expect(words.length, greaterThanOrEqualTo(4));
      expect(nativeWordMatches, greaterThanOrEqualTo(4));
      await tester.tap(find.byKey(const Key('play-pause')));
      await tester.pump(const Duration(seconds: 1));
      expect(playback!.wantedPlaying, isFalse);
      await tester.tap(find.byKey(const Key('reader-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-offline')));
      final store = await OfflineStore.open();
      var saved = await store.documents();
      for (var i = 0; i < 80 && saved.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        saved = await store.documents();
      }
      expect(saved.length, 1);
      expect(saved.single.document['id'], id);
      expect(await saved.single.pdf.exists(), isTrue);
      expect(
        objects(object(saved.single.payload['plan'])['segments']),
        isNotEmpty,
      );
      debugPrint(
        'Server PDF and its complete reading plan were saved privately for on-phone narration.',
      );
      debugPrint(
        'Native audio and moving PDF word highlights verified from server timing windows.',
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      debugPrint('Cover-screen layout verified without overflow.');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
