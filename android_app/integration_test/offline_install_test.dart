import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/offline_library.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('download and verify the full-quality offline voice pack', (
    tester,
  ) async {
    await prepareOfflineAssets(tester);
  });
}

Future<void> prepareOfflineAssets(WidgetTester tester) async {
  final preferences = await SharedPreferences.getInstance();
  await configureServer(preferences);
  await preferences.setString('offlineVoice', 'am_michael');
  final store = await OfflineStore.open();
  await tester.pumpWidget(
    MaterialApp(home: OfflineLibraryPage(preferences: preferences)),
  );
  await tester.pumpAndSettle();
  if (!await store.packInstalled) {
    await tester.tap(find.byKey(const Key('download-offline-pack')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    for (var i = 0; i < 1200 && !await store.packInstalled; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.textContaining('installation failed').evaluate().isNotEmpty) {
        fail('Offline voice installation failed in the native UI.');
      }
    }
  }
  expect(await store.packInstalled, isTrue);
  final response = await http.get(testInstaller.resolve('/offline-check.pdf'));
  expect(response.statusCode, 200);
  final saved = await store.importPdf(
    response.bodyBytes,
    'Offline-on-phone-check.pdf',
  );
  expect(saved.payload['parsedDocument'], isNotNull);
  expect(await saved.pdf.exists(), isTrue);
  if (await store.audio.exists()) await store.audio.delete(recursive: true);
  debugPrint(
    'Pinned voice pack installed and a PDF saved locally; generated audio cache is empty.',
  );
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}
