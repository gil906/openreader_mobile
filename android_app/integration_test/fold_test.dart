import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/main.dart' as app;
import 'package:openreader_native/playback.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_config.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'multi-page fold retention, compact controls and paragraph seeking',
    (tester) async {
      const id =
          '9d30bcbee2dcbfe385f6fa1ef800d8920832e9c6c37c4f51d1fa2c85074d64ee';
      final preferences = await SharedPreferences.getInstance();
      await configureServer(preferences);
      await preferences.setInt('progress:$testServer:$id', 0);
      await preferences.setInt('resume:$testServer:$id', 0);
      await preferences.setBool('pdfDarkMode', false);
      tester.view.physicalSize = const Size(950, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
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
        for (var i = 0; i < seconds * 4; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (condition()) return;
        }
        fail('Timed out waiting for fold regression state');
      }

      final entry = find.byKey(const Key('document-$id'));
      await waitFor(() => entry.evaluate().isNotEmpty);
      await tester.tap(entry);
      ReaderPlayback? playback;
      await waitFor(() {
        for (final element in find.byType(AnimatedBuilder).evaluate()) {
          final builder = element.widget as AnimatedBuilder;
          if (builder.animation is ReaderPlayback) {
            playback = builder.animation as ReaderPlayback;
            if (playback!.error != null) fail(playback!.error!);
            return playback!.connected &&
                find.byType(PdfViewer).evaluate().isNotEmpty;
          }
        }
        return false;
      });
      final pdfElement = find.byType(PdfViewer).evaluate().single;
      final controller = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .controller!;
      await waitFor(() => controller.isReady);
      final originalDocument = controller.document;
      expect(controller.pageCount, 4);
      await controller.goToPage(pageNumber: 3, duration: Duration.zero);
      await tester.pump(const Duration(seconds: 1));

      final passages = playback!.plan
          .where(
            (segment) =>
                integer(object(segment['locator'])['page']) == 3 &&
                (segment['text'] as String).length > 100,
          )
          .toList();
      expect(passages.length, greaterThanOrEqualTo(2));
      final first = passages[0];
      final second = passages[1];
      final pages = objects(
        object(playback!.payload!['parsedDocument'])['pages'],
      );

      Rect bounds(Json segment) {
        final block = pages
            .expand((page) => objects(page['blocks']))
            .firstWhere(
              (block) => block['id'] == object(segment['locator'])['blockId'],
            );
        final fragment = objects(block['fragments'])
            .firstWhere((fragment) => integer(fragment['page']) == 3);
        final values = fragment['bbox'] as List;
        return Rect.fromLTRB(
          (values[0] as num).toDouble(),
          (values[1] as num).toDouble(),
          (values[2] as num).toDouble(),
          (values[3] as num).toDouble(),
        );
      }

      Future<void> tapPassage(Json segment) async {
        final box = bounds(segment);
        final page = controller.pages[2];
        await controller.goToRectInsidePage(
          pageNumber: 3,
          rect: PdfRect(
            box.left,
            page.height - box.top,
            box.right,
            page.height - box.bottom,
          ),
          duration: Duration.zero,
        );
        await tester.pump(const Duration(milliseconds: 100));
        final layout = controller.layout.pageLayouts[2];
        final point = controller.documentToGlobal(
          Offset(
            layout.left + box.center.dx / page.width * layout.width,
            layout.top + box.center.dy / page.height * layout.height,
          ),
        )!;
        expect(tester.getRect(find.byType(PdfViewer)).contains(point), isTrue);
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<double> paperBrightness() async {
        await tester.pump(const Duration(milliseconds: 600));
        final page = controller.pages[2];
        final layout = controller.layout.pageLayouts[2];
        final local = controller.documentToLocal(
          Offset(
            layout.left + 20 / page.width * layout.width,
            layout.top + bounds(first).center.dy / page.height * layout.height,
          ),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('pdf-surface')),
        );
        expect((Offset.zero & boundary.size).contains(local), isTrue);
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final index = (local.dy.floor() * image.width + local.dx.floor()) * 4;
          return (data.getUint8(index) +
                  data.getUint8(index + 1) +
                  data.getUint8(index + 2)) /
              3;
        } finally {
          image.dispose();
        }
      }

      await tapPassage(first);
      await waitFor(() => !playback!.preparing);
      expect(playback!.currentOrdinal, integer(first['ordinal']));
      expect(playback!.wantedPlaying, isFalse);
      expect(find.byKey(const Key('now-reading-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('toggle-transcript')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('now-reading-panel')), findsNothing);
      await tester.tap(find.byKey(const Key('toggle-transcript')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('now-reading-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('toggle-transcript')));
      await tester.pump(const Duration(milliseconds: 400));
      final barHeight =
          tester.getSize(find.byKey(const Key('playback-bar'))).height +
          tester.getSize(find.byKey(const Key('page-controls'))).height;
      expect(barHeight, lessThan(170));

      Future<void> resize(Size size) async {
        tester.view.physicalSize = size;
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(PdfViewer).evaluate().single, same(pdfElement));
        expect(controller.document, same(originalDocument));
        expect(controller.pageNumber, 3);
        expect(tester.takeException(), isNull);
      }

      await resize(const Size(390, 844));
      expect(find.byKey(const Key('now-reading-panel')), findsNothing);
      await tester.tap(find.byKey(const Key('toggle-transcript')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('now-reading-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('toggle-transcript')));
      await tester.pump(const Duration(milliseconds: 400));
      await resize(const Size(950, 1000));
      expect(find.byKey(const Key('now-reading-panel')), findsNothing);
      debugPrint(
        'Page three and PDF instance retained across fold and transcript changes.',
      );

      final uiBrightness = Theme.of(tester.element(find.byType(PdfViewer)))
          .brightness;
      expect(await paperBrightness(), greaterThan(220));
      await tester.tap(find.byKey(const Key('toggle-pdf-dark')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(await paperBrightness(), lessThan(60));
      expect(
        Theme.of(tester.element(find.byType(PdfViewer))).brightness,
        uiBrightness,
      );
      expect(preferences.getBool('pdfDarkMode'), isTrue);
      expect(find.byType(PdfViewer).evaluate().single, same(pdfElement));
      expect(controller.document, same(originalDocument));
      expect(controller.pageNumber, 3);
      await tester.tap(find.byKey(const Key('toggle-pdf-dark')));
      expect(await paperBrightness(), greaterThan(220));
      await tester.tap(find.byKey(const Key('toggle-pdf-dark')));
      expect(await paperBrightness(), lessThan(60));

      final normalSize = tester.getSize(find.byType(PdfViewer));
      await tester.tap(find.byKey(const Key('enter-fullscreen')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('playback-bar')), findsNothing);
      expect(find.byKey(const Key('page-controls')), findsNothing);
      expect(find.byKey(const Key('exit-fullscreen')), findsOneWidget);
      expect(
        tester.getSize(find.byType(PdfViewer)).height,
        greaterThan(normalSize.height),
      );
      expect(
        tester.view.viewPadding.top,
        0,
        reason: 'Android status bar must be hidden',
      );
      expect(
        tester.view.viewPadding.bottom,
        0,
        reason: 'Android navigation bar must be hidden',
      );
      await resize(const Size(390, 844));
      await resize(const Size(950, 1000));
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(PdfViewer).evaluate().single, same(pdfElement));
      expect(find.byKey(const Key('exit-fullscreen')), findsNothing);
      expect(controller.pageNumber, 3);
      debugPrint(
        'Actual PDF pixels darken without changing app theme; fullscreen hides system bars and Back restores the reader.',
      );

      await tester.tap(find.byKey(const Key('play-pause')));
      await waitFor(() {
        if (playback!.error != null) fail(playback!.error!);
        return !playback!.preparing &&
            playback!.player.position.inMilliseconds > 700;
      }, 240);
      final before = playback!.player.position;
      await tester.tap(find.byKey(const Key('enter-fullscreen')));
      await tester.pump(const Duration(milliseconds: 500));
      await resize(const Size(390, 844));
      await resize(const Size(950, 1000));
      expect(playback!.wantedPlaying, isTrue);
      expect(playback!.player.position, greaterThanOrEqualTo(before));
      await tester.tap(find.byKey(const Key('fullscreen-play-pause')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(playback!.wantedPlaying, isFalse);
      await tester.tap(find.byKey(const Key('fullscreen-play-pause')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(playback!.wantedPlaying, isTrue);
      await tester.tap(find.byKey(const Key('exit-fullscreen')));
      await tester.pump(const Duration(milliseconds: 500));

      await tapPassage(second);
      await tapPassage(first);
      await tapPassage(second);
      await waitFor(() {
        if (playback!.error != null) fail(playback!.error!);
        return !playback!.preparing &&
            playback!.currentOrdinal == integer(second['ordinal']) &&
            playback!.player.position.inMilliseconds > 400;
      }, 180);
      expect(playback!.wantedPlaying, isTrue);
      expect(controller.pageNumber, 3);
      await tester.tap(find.byKey(const Key('play-pause')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(playback!.wantedPlaying, isFalse);
      debugPrint(
        'Live narration survived folding; latest tapped paragraph resumed correctly.',
      );
      await tester.pageBack();
      await waitFor(() => entry.evaluate().isNotEmpty);
      await tester.tap(entry);
      await waitFor(() => find.byType(PdfViewer).evaluate().isNotEmpty);
      expect(
        tester
            .widget<PdfViewer>(find.byType(PdfViewer))
            .params
            .pageImageColorFilter,
        isNotNull,
      );
      expect(find.byKey(const Key('enter-fullscreen')), findsOneWidget);
      debugPrint(
        'PDF dark mode preference survives closing and reopening a document.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
