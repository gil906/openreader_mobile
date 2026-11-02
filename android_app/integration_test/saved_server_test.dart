import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/offline_engine.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/playback.dart';
import 'package:openreader_native/reader.dart';
import 'package:openreader_native/server_narration.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_install_test.dart' show prepareOfflineAssets;
import 'test_config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'numeric phone speech and saved server MP3 with PDF words in airplane mode',
    (tester) async {
      await prepareOfflineAssets(tester);
      final preferences = await SharedPreferences.getInstance();
      final store = await OfflineStore.open();
      final engine = OfflineVoiceEngine(store);
      for (final text in ['123', '0', '12', 'Port 443 / IPv6', '---']) {
        final speech = await engine.synthesize(text, 'am_michael');
        expect(speech.durationMs, greaterThan(0));
        expect(await File(speech.path).length(), greaterThan(44));
        if (text == '123') {
          expect(objects(speech.alignment['words']).single['text'], '123');
        }
      }
      await engine.close();
      debugPrint('Numeric phone speech verified with the actual Kokoro model.');
      final source = (await store.documents()).firstWhere(
        (doc) => doc.document['name'] == 'Offline-on-phone-check.pdf',
      );
      final api = OpenReaderApi(Uri.parse(testServer));
      await api.signIn(
        testEmail,
        const String.fromEnvironment('TEST_PASSWORD'),
      );
      final uploaded = await api.uploadPdf(
        await source.pdf.readAsBytes(),
        'Narration regression demo.pdf',
      );
      Json payload = {};
      for (var i = 0; i < 180; i++) {
        final result = await api.post(
          '/api/documents/${uploaded['id']}/reader-bootstrap',
        );
        if (result['status'] == 'ready') {
          payload = object(result['payload']);
          break;
        }
        if (result['status'] == 'error') {
          fail('Synthetic PDF preparation failed');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(payload, isNotEmpty);
      final document = await store.save(
        origin: api.base.origin,
        account: 'test',
        document: uploaded,
        payload: payload,
        bytes: await source.pdf.readAsBytes(),
      );
      final saved = ServerNarration(document);
      var lastStage = '';
      expect(
        await saved.prepare(
          api,
          payload,
          canceled: () => false,
          onProgress: (message, _) {
            if (message != lastStage) debugPrint(message);
            lastStage = message;
          },
        ),
        isTrue,
      );
      expect(await saved.load(), isNotNull);
      await preferences.setString('offline-source:${document.key}', 'server');
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
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            api: api,
            preferences: preferences,
            document: uploaded,
            offline: document,
          ),
        ),
      );
      ReaderPlayback? reader;
      Future<void> waitFor(
        bool Function() condition, [
        int seconds = 90,
      ]) async {
        for (var i = 0; i < seconds * 4; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (condition()) return;
        }
        fail('Timed out waiting for saved server playback');
      }

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
      expect(reader!.usesSavedServer, isTrue);
      await reader!.startAt(0);
      expect(reader!.error, isNull);
      final ordinals = <int>{};
      await waitFor(() {
        if (reader!.error != null) fail(reader!.error!);
        ordinals.add(reader!.currentOrdinal);
        return ordinals.length >= 2 &&
            find.byKey(const Key('pdf-spoken-word')).evaluate().isNotEmpty;
      });
      expect(reader!.preparing, isFalse);
      expect(await store.packInstalled, isFalse);
      final total = reader!.player.duration!.inMilliseconds;
      expect((total - reader!.durationMs).abs(), lessThan(1500));
      final ordinal = reader!.plan.length - 1;
      await reader!.startAt(ordinal);
      await waitFor(
        () => reader!.currentOrdinal == ordinal && reader!.player.playing,
      );
      expect(reader!.usesSavedServer, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      api.close();
      debugPrint(
        'Saved server MP3 crossed passages and sought with PDF word highlighting, without model or network.',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
