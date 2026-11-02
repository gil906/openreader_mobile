import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:openreader_native/alignment.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/offline_engine.dart';
import 'package:openreader_native/offline_narration.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/passages.dart';
import 'package:openreader_native/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'legacy nine-passage checkpoints resume at a numeric passage unchanged',
    () async {
      final root = await Directory.systemTemp.createTemp('prepared-number-');
      addTearDown(() => root.delete(recursive: true));
      final store = OfflineStore(root);
      final doc = await store.save(
        origin: 'https://reader.example.com',
        account: 'owner',
        document: {'id': 'numbers', 'name': 'Numbers.pdf'},
        payload: {
          'plan': {
            'segments': [
              for (var i = 0; i < 11; i++)
                {
                  'ordinal': i,
                  'text': i == 9
                      ? '123'
                      : i == 10
                      ? '12'
                      : 'Synthetic passage $i',
                  'locator': {'page': 1, 'blockId': 'block-$i'},
                },
            ],
          },
        },
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nsynthetic')),
      );
      final source = await File('${root.path}/sample.wav')
          .writeAsBytes(Uint8List(144));
      var stopped = false;
      final book = SavedNarration(doc, 'am_michael');
      await book.prepare(
        (text) async => OfflineSpeech(
          source.path,
          1000,
          approximateOfflineAlignment(text, 1000),
        ),
        canceled: () => stopped,
        onProgress: (p) => stopped = p.completed == 9,
      );
      final checkpoint = File('${book.directory.path}/progress.json');
      final legacy = object(jsonDecode(await checkpoint.readAsString()))
        ..remove('nonSpeech');
      await checkpoint.writeAsString(jsonEncode(legacy));
      final generated = <String>[];
      final complete = await SavedNarration(doc, 'am_michael').prepare(
        (text) async {
          generated.add(text);
          return OfflineSpeech(
            source.path,
            1000,
            approximateOfflineAlignment(text, 1000),
          );
        },
        canceled: () => false,
        onProgress: (_) {},
      );
      expect(complete.complete, isTrue);
      expect(generated, ['123', '12']);
      expect(complete.separators, 0);
    },
  );
  test('full PDF narration resumes, survives cache eviction, and is voice-specific', () async {
    final root = await Directory.systemTemp.createTemp('prepared-book-');
    addTearDown(() => root.delete(recursive: true));
    final store = OfflineStore(root);
    final document = await _document(store);
    final book = SavedNarration(document, 'am_michael');
    var generated = 0;
    var canceled = false;
    Future<OfflineSpeech> generate(String text) async {
      generated++;
      await store.audio.create(recursive: true);
      final file = await File('${store.audio.path}/sample-$generated.wav')
          .writeAsBytes(Uint8List(144));
      if (generated == 2) canceled = true;
      return OfflineSpeech(
        file.path,
        10000,
        approximateOfflineAlignment(text, 10000),
      );
    }

    final partial = await book.prepare(
      generate,
      canceled: () => canceled,
      onProgress: (_) {},
    );
    expect(partial.completed, 2);
    expect(partial.complete, isFalse);
    canceled = false;
    final complete = await book.prepare(
      generate,
      canceled: () => false,
      onProgress: (_) {},
    );
    expect(complete.complete, isTrue);
    expect(generated, 6);
    await store.audio.delete(recursive: true);
    final reopened = SavedNarration(document, 'am_michael');
    expect((await reopened.progress()).complete, isTrue);
    for (var ordinal = 0; ordinal < 6; ordinal++) {
      expect(await File((await reopened.load(ordinal))!.path).exists(), isTrue);
    }
    expect(
      (await SavedNarration(document, 'am_fenrir').progress()).completed,
      0,
    );
    final resaved = await store.save(
      origin: document.origin,
      account: 'owner',
      document: document.document,
      payload: document.payload,
      bytes: await document.pdf.readAsBytes(),
    );
    expect(
      (await SavedNarration(resaved, 'am_michael').progress()).complete,
      isTrue,
    );
    await store.remove(resaved);
    expect(await reopened.directory.exists(), isFalse);
  });

  test(
    'prepared narration plays as one queued session without a voice model',
    () async {
      SharedPreferences.setMockInitialValues({
        'offlinePlaybackSpeed': .8,
        'serverPlaybackSpeed': 1.1,
      });
      final preferences = await SharedPreferences.getInstance();
      final root = await Directory.systemTemp.createTemp('prepared-playback-');
      addTearDown(() => root.delete(recursive: true));
      final store = OfflineStore(root);
      final document = await _document(store);
      await SavedNarration(document, 'am_michael').prepare(
        (text) async {
          await store.audio.create(recursive: true);
          final file = await File('${store.audio.path}/source.wav')
              .writeAsBytes(Uint8List(144));
          return OfflineSpeech(
            file.path,
            10000,
            approximateOfflineAlignment(text, 10000),
          );
        },
        canceled: () => false,
        onProgress: (_) {},
      );
      await store.audio.delete(recursive: true);
      expect(await store.packInstalled, isFalse);
      final audio = _PlaylistAudio();
      final api = OpenReaderApi(Uri.parse(document.origin));
      final reader = ReaderPlayback(
        api,
        'book',
        preferences,
        offline: document,
        audioPlayer: audio,
      );
      await reader.prepare();
      expect(reader.speed, .8);
      await reader.startAt(0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reader.error, isNull);
      expect(audio.loads, 1);
      expect(audio.sources.length, 6);
      final stops = audio.stops;
      audio.advance(1, const Duration(milliseconds: 1000));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(reader.currentOrdinal, 1);
      expect(reader.wantedPlaying, isTrue);
      expect(reader.preparing, isFalse);
      expect(audio.loads, 1);
      expect(audio.stops, stops);
      expect(preferences.getInt('offline-progress:${document.origin}:book'), 1);
      await reader.setSpeed(.75);
      expect(preferences.getDouble('offlinePlaybackSpeed'), .75);
      expect(preferences.getDouble('serverPlaybackSpeed'), 1.1);
      await reader.close();
      api.close();
    },
  );

  test('PDF word glyphs ignore interleaved adjacent columns', () {
    const text = 'Alpha OTHER beta gamma';
    final rectangles = <Rect>[];
    for (var i = 0; i < text.length; i++) {
      rectangles.add(
        i >= 6 && i <= 10
            ? Rect.fromLTWH(170 + (i - 6) * 5, 0, 5, 10)
            : Rect.fromLTWH(10 + (i % 6) * 5, i < 6 ? 0 : 25, 5, 10),
      );
    }
    final glyphs = pdfWordGlyphs(
      pageText: text,
      characterRects: rectangles,
      blockBounds: [const Rect.fromLTWH(0, 0, 100, 100)],
      segmentText: 'Alpha beta gamma',
      word: const HighlightWord(
        text: 'beta',
        start: 6,
        end: 10,
        page: 1,
        ordinal: 0,
        wordIndex: 1,
      ),
    );
    expect(glyphs.map((index) => text[index]).join(), 'beta');
  });

  test('word context maps partial page text and PDF ligatures', () {
    const page = 'the final paragraph continues';
    const source =
        'Earlier words from the previous page. Now the final paragraph continues on another page.';
    final start = source.indexOf('paragraph');
    final glyphs = pdfWordGlyphs(
      pageText: page,
      characterRects: [
        for (var i = 0; i < page.length; i++) Rect.fromLTWH(i * 5, 0, 5, 10),
      ],
      blockBounds: [],
      segmentText: source,
      word: HighlightWord(
        text: 'paragraph',
        start: start,
        end: start + 9,
        page: 1,
        ordinal: 0,
        wordIndex: 10,
      ),
    );
    expect(glyphs.map((index) => page[index]).join(), 'paragraph');
    const ligature = 'ofﬁce';
    final office = pdfWordGlyphs(
      pageText: ligature,
      characterRects: [
        for (var i = 0; i < ligature.length; i++)
          Rect.fromLTWH(i * 5, 0, 5, 10),
      ],
      blockBounds: [],
      segmentText: 'office',
      word: const HighlightWord(
        text: 'office',
        start: 0,
        end: 6,
        page: 1,
        ordinal: 0,
        wordIndex: 0,
      ),
    );
    expect(office.length, 5);
  });
}

Future<OfflineDocument> _document(OfflineStore store) => store.save(
  origin: 'http://reader.example.test',
  account: 'owner',
  document: {'id': 'book', 'name': 'Synthetic demo'},
  payload: {
    'parsedDocument': {'pages': []},
    'plan': {
      'segments': [
        for (var i = 0; i < 6; i++)
          {
            'ordinal': i,
            'text': 'This is demo paragraph number $i.',
            'locator': {'page': 1, 'blockId': 'demo-$i'},
          },
      ],
    },
  },
  bytes: Uint8List.fromList('%PDF-demo'.codeUnits),
);

class _PlaylistAudio extends Fake implements AudioPlayer {
  final _indices = StreamController<int?>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final sources = <AudioSource>[];
  int loads = 0;
  int stops = 0;
  int _index = 0;
  Duration _position = Duration.zero;
  @override
  Stream<int?> get currentIndexStream => _indices.stream;
  @override
  int? get currentIndex => _index;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Duration get position => _position;
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  ProcessingState get processingState => ProcessingState.ready;
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    loads++;
    sources
      ..clear()
      ..addAll(audioSources);
    _index = initialIndex ?? 0;
    _position = initialPosition ?? Duration.zero;
    return const Duration(seconds: 10);
  }

  @override
  Future<void> addAudioSource(AudioSource source) async {
    sources.add(source);
  }

  void advance(int index, Duration position) {
    _index = index;
    _position = position;
    _indices.add(index);
    _positions.add(position);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> dispose() async {
    await _indices.close();
    await _positions.close();
  }
}
