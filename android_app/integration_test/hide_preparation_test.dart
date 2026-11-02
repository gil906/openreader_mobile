import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/offline_library.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/server_narration.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'hide admitted server work, read the PDF, and restore server resume controls',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await configureServer(preferences);
      final api = OpenReaderApi(Uri.parse(testServer));
      await api.signIn(
        testEmail,
        const String.fromEnvironment('TEST_PASSWORD'),
      );
      final bytes = (await http.get(testInstaller.resolve('/hide-check.pdf')))
          .bodyBytes;
      final uploaded = await api.uploadPdf(bytes, 'Hide preparation demo.pdf');
      Json payload = {};
      for (var i = 0; i < 180; i++) {
        final response = await api.post(
          '/api/documents/${uploaded['id']}/reader-bootstrap',
        );
        if (response['status'] == 'ready') {
          payload = object(response['payload']);
          break;
        }
        if (response['status'] == 'error') {
          fail('Synthetic PDF preparation failed.');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(payload, isNotEmpty);
      final store = await OfflineStore.open();
      final document = await store.save(
        origin: api.base.origin,
        account: 'hide-test',
        document: uploaded,
        payload: payload,
        bytes: bytes,
      );
      final pending = ServerNarration.pendingKey(document);
      await preferences.remove(pending);
      await tester.pumpWidget(
        MaterialApp(home: OfflineLibraryPage(preferences: preferences)),
      );
      Future<void> waitFor(
        bool Function() condition, [
        int seconds = 120,
      ]) async {
        for (var i = 0; i < seconds * 4; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (condition()) return;
        }
        fail('Timed out waiting for hide/resume preparation.');
      }

      final entry = find.byKey(Key('offline-document-${document.key}'));
      Future<void> openPreparation() async {
        await waitFor(() => entry.evaluate().isNotEmpty);
        await tester.ensureVisible(entry);
        await tester.tap(find.byKey(Key('offline-options-${document.key}')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Prepare entire PDF audio'));
        await tester.pump(const Duration(milliseconds: 400));
      }

      await openPreparation();
      await tester.tap(
        find.byKey(const ValueKey('preparation-generator-phone')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Server / save on phone').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('start-prepare-audio')));
      final hide = find.byKey(const Key('hide-server-preparation'));
      await waitFor(
        () =>
            hide.evaluate().isNotEmpty &&
            tester.widget<TextButton>(hide).onPressed != null,
      );
      await tester.tap(hide);
      await waitFor(() => find.byType(AlertDialog).evaluate().isEmpty);
      expect(preferences.getBool(pending), isTrue);
      await waitFor(
        () => find.textContaining('Server audio pending').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await waitFor(() => find.byType(PdfViewer).evaluate().isNotEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      final plan = object(payload['plan']);
      final body = <String, dynamic>{
        ...object(object(payload['playback'])['request']),
        'planId': plan['planId'],
        'planObjectKey': plan['planObjectKey'],
        'planSignature': plan['planSignature'],
        'startIntent': {'selectedOrdinal': 0},
        'format': 'mp3',
        'speed': 1,
        'includeProgress': true,
        'action': 'resolve',
      };
      final snapshot = await api.post('/api/tts/export/resolve', body);
      expect([
        'queued',
        'generating',
        'complete',
      ], contains(object(snapshot['generation'])['state']));
      final operation = object(snapshot['generation'])['operationId'];
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump(const Duration(seconds: 1));
      await openPreparation();
      expect(find.text('Server / save on phone'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
      await tester.tap(find.byKey(const Key('start-prepare-audio')));
      final close = find.widgetWithText(TextButton, 'Close');
      await waitFor(
        () =>
            close.evaluate().isNotEmpty ||
            hide.evaluate().isNotEmpty &&
                tester.widget<TextButton>(hide).onPressed != null,
      );
      if (close.evaluate().isNotEmpty) {
        expect(preferences.getBool(pending), isNull);
        expect(await ServerNarration(document).load(), isNotNull);
        await tester.tap(close);
      } else {
        await tester.binding.handlePopRoute();
        await waitFor(() => find.byType(AlertDialog).evaluate().isEmpty);
        expect(preferences.getBool(pending), isTrue);
        final resumed = await api.post('/api/tts/export/resolve', body);
        expect([
          'queued',
          'generating',
          'complete',
        ], contains(object(resumed['generation'])['state']));
        if (operation != null &&
            object(resumed['generation'])['operationId'] != null) {
          expect(object(resumed['generation'])['operationId'], operation);
        }
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      api.close();
      debugPrint(
        'Hide and Android Back left server work admitted; native PDF stayed usable; reopening restored Server/Resume without replacing the job.',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
