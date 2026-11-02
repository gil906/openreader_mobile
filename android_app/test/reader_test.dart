import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:openreader_native/alignment.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/passages.dart';
import 'package:openreader_native/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'detailed cursor windows preserve cached words and rebuild audio offsets',
    () {
      final oldWords = {
        'words': [
          {'text': 'Earlier', 'startSec': 0},
        ],
      };
      final newWords = {
        'words': [
          {'text': 'Current', 'startSec': 0},
        ],
      };
      final previous = <Json>[
        {
          'ordinal': 0,
          'durationMs': 100,
          'generated': true,
          'alignment': oldWords,
        },
        {'ordinal': 1, 'durationMs': 200, 'generated': false},
        {'ordinal': 2, 'durationMs': 300, 'generated': false},
      ];
      final merged = mergeTimeline(previous, [
        {
          'ordinal': 1,
          'durationMs': 250,
          'generated': true,
          'alignment': newWords,
          'startMs': 900,
          'endMs': 1150,
        },
      ]);
      expect(merged.map((row) => row['startMs']), [0, 100, 350]);
      expect(merged.map((row) => row['endMs']), [100, 350, 650]);
      expect(merged[0]['alignment'], oldWords);
      expect(merged[1]['alignment'], newWords);
      final stale = mergeTimeline(merged, [
        {'ordinal': 0, 'durationMs': 80, 'generated': false, 'alignment': null},
      ]);
      expect(stale[0]['alignment'], oldWords);
      expect(stale[0]['durationMs'], 100);
    },
  );

  test('word timing uses segment-relative seconds at exact boundaries', () {
    final timeline = <Json>[
      {
        'ordinal': 4,
        'startMs': 1000,
        'endMs': 2500,
        'locator': {'page': 3},
        'alignment': {
          'words': [
            {
              'text': 'Hello',
              'startSec': 0,
              'endSec': 0.5,
              'charStart': 0,
              'charEnd': 5,
            },
            {
              'text': 'world',
              'startSec': 0.5,
              'endSec': 1,
              'charStart': 6,
              'charEnd': 11,
            },
          ],
        },
      },
    ];
    expect(wordAt(timeline, 999), isNull);
    expect(wordAt(timeline, 1000)?.text, 'Hello');
    final word = wordAt(timeline, 1500)!;
    expect(word.text, 'world');
    expect(word.page, 3);
    expect(word.ordinal, 4);
    expect(wordAt(timeline, 2000)?.text, 'world');
    expect(wordAt(timeline, 2500), isNull);
  });

  test('native PDF mapping handles line wraps and repeated spoken words', () {
    const word = HighlightWord(
      text: 'again',
      start: 17,
      end: 22,
      page: 1,
      ordinal: 0,
      wordIndex: 3,
    );
    const page = 'Title\r\nRead again,\r\nthen again.';
    final range = findWordRange(page, 'Read again, then again.', word)!;
    expect(page.substring(range.start, range.end), 'again');
    expect(range.start, page.lastIndexOf('again'));
  });

  test('missing offsets never paint an ambiguous repeated word', () {
    const word = HighlightWord(
      text: 'again',
      start: -1,
      end: -1,
      page: 1,
      ordinal: 0,
      wordIndex: 0,
    );
    expect(findWordRange('again again', 'again again', word), isNull);
    expect(findWordRange('A different page', 'again', word), isNull);
  });

  test(
    'server URLs exclude credentials, query strings, and unsupported schemes',
    () {
      expect(
        OpenReaderApi.parseServer('http://reader.example.test:3003/').origin,
        'http://reader.example.test:3003',
      );
      for (final url in [
        'file:///etc/passwd',
        Uri(scheme: 'http', userInfo: 'example', host: 'localhost').toString(),
        'https://reader.example/?token=secret',
        'http://localhost/app',
      ]) {
        expect(
          () => OpenReaderApi.parseServer(url),
          throwsA(isA<ReaderException>()),
        );
      }
    },
  );

  test(
    'API errors are explicit instead of returning an empty library',
    () async {
      final api = OpenReaderApi(
        Uri.parse('http://reader.local:3003'),
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'error': 'Busy generating'}), 503),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.get('/api/documents'),
        throwsA(
          isA<ReaderException>().having(
            (e) => e.message,
            'message',
            'Busy generating',
          ),
        ),
      );
      await expectLater(
        api.get('http://other-server/private'),
        throwsA(isA<ReaderException>()),
      );
    },
  );

  test('paragraph hit testing respects page, skipped blocks and columns', () {
    final pages = <Json>[
      {
        'blocks': [
          {
            'id': 'header',
            'fragments': [
              {
                'page': 2,
                'bbox': [10, 0, 90, 20],
              },
            ],
          },
          {
            'id': 'left',
            'fragments': [
              {
                'page': 2,
                'bbox': [10, 30, 90, 100],
              },
            ],
          },
          {
            'id': 'right',
            'fragments': [
              {
                'page': 2,
                'bbox': [110, 30, 190, 100],
              },
            ],
          },
        ],
      },
    ];
    final plan = <Json>[
      {
        'ordinal': 7,
        'locator': {'blockId': 'left', 'page': 2},
      },
      {
        'ordinal': 8,
        'locator': {'blockId': 'right', 'page': 2},
      },
    ];
    Json? hit(int page, Offset point) =>
        passageAtPoint(page: page, point: point, pages: pages, plan: plan);
    expect(hit(2, const Offset(140, 50))?['ordinal'], 8);
    expect(hit(2, const Offset(40, 50))?['ordinal'], 7);
    expect(hit(1, const Offset(40, 50)), isNull);
    expect(hit(2, const Offset(40, 10)), isNull);
    expect(hit(2, const Offset(100, 50)), isNull);
  });

  test('a tap inside a long paragraph selects its matching audio chunk', () {
    final pages = <Json>[
      {
        'blocks': [
          {
            'id': 'long',
            'fragments': [
              {
                'page': 1,
                'bbox': [0, 0, 100, 50],
              },
            ],
          },
        ],
      },
    ];
    final plan = <Json>[
      {
        'ordinal': 0,
        'text': 'First half.',
        'locator': {'blockId': 'long', 'page': 1},
      },
      {
        'ordinal': 1,
        'text': 'Second half.',
        'locator': {'blockId': 'long', 'page': 1},
      },
    ];
    const text = 'First half.\nSecond half.';
    final rects = [
      for (var i = 0; i < text.length; i++)
        Rect.fromLTWH((i < 12 ? i : i - 12) * 5, i < 12 ? 0 : 25, 5, 10),
    ];
    final hit = passageAtPoint(
      page: 1,
      point: const Offset(12, 30),
      pages: pages,
      plan: plan,
      pageText: text,
      characterRects: rects,
    );
    expect(hit?['ordinal'], 1);
  });

  test(
    'rapid paragraph choices keep the latest target and clear old offsets',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final audio = _FakeAudio();
      final firstSeen = Completer<void>();
      final firstResponse = Completer<http.Response>();
      final created = <int>[];
      final activeCursors = <int>[];
      Json session(int ordinal) => {
        'sessionId': 'session',
        'sessionInstanceId': 'instance-$ordinal',
        'audioUrl': 'http://reader.local:3004/audio',
        'timelineUrl': '/timeline',
      };
      final rows = <Json>[
        for (var i = 0; i < 3; i++)
          {
            'ordinal': i,
            'startMs': i * 10000,
            'endMs': (i + 1) * 10000,
            'durationMs': 10000,
            'generated': true,
          },
      ];
      final api = OpenReaderApi(
        Uri.parse('http://reader.local:3003'),
        client: MockClient((request) async {
          if (request.url.path == '/api/tts/stream/sessions') {
            final body = object(jsonDecode(request.body));
            final ordinal = integer(
              object(body['startIntent'])['selectedOrdinal'],
            );
            created.add(ordinal);
            if (created.length == 1) {
              firstSeen.complete();
              return firstResponse.future;
            }
            return http.Response(jsonEncode(session(ordinal)), 202);
          }
          if (request.url.path.endsWith('/cursor')) {
            final body = object(jsonDecode(request.body));
            if (body['playbackActive'] == true) {
              activeCursors.add(integer(body['ordinal']));
            }
            return http.Response('{}', 200);
          }
          expect(request.url.path, '/timeline');
          expect(request.url.queryParameters['rows'], 'window');
          expect(request.url.queryParameters['limit'], '8');
          expect(
            request.url.queryParameters['minOrdinal'],
            '${created.last > 0 ? created.last - 1 : 0}',
          );
          return http.Response(jsonEncode({'segments': rows}), 200);
        }),
      );
      final reader = ReaderPlayback(
        api,
        'book',
        preferences,
        audioPlayer: audio,
      );
      reader.payload = {
        'plan': {
          'planObjectKey': 'plan',
          'segments': [
            for (var i = 0; i < 3; i++) {'ordinal': i, 'text': 'Passage $i'},
          ],
        },
        'playback': {
          'request': {'documentId': 'book'},
        },
      };
      reader.timeline = rows;
      final first = reader.startAt(0);
      await firstSeen.future;
      final second = reader.selectAt(1);
      final last = reader.selectAt(2);
      audio.emitPosition(const Duration(seconds: 35));
      expect(reader.currentOrdinal, 2);
      firstResponse.complete(http.Response(jsonEncode(session(0)), 202));
      await Future.wait([first, second, last]);
      expect(created, [0, 2]);
      expect(activeCursors, [2]);
      expect(audio.loadedOrdinals, [2]);
      expect(reader.currentOrdinal, 2);

      await reader.toggle();
      await reader.selectAt(1);
      expect(reader.wantedPlaying, isFalse);
      expect(reader.currentOrdinal, 1);
      expect(preferences.getInt('resume:http://reader.local:3003:book'), 0);
      expect(created, [0, 2]);
      await reader.toggle();
      expect(audio.loadedOrdinals, [2, 1]);
      expect(audio.seeks, isEmpty);
      await reader.close();
      api.close();
    },
  );
}

class _FakeAudio extends Fake implements AudioPlayer {
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final loadedOrdinals = <int>[];
  final seeks = <Duration?>[];
  Duration _position = Duration.zero;
  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  Duration get position => _position;
  @override
  ProcessingState get processingState => ProcessingState.ready;
  void emitPosition(Duration position) {
    _position = position;
    _positions.add(position);
  }

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loadedOrdinals.add(
      int.parse(Uri.parse(url).queryParameters['fromOrdinal']!),
    );
    emitPosition(Duration.zero);
    return const Duration(seconds: 30);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(position);
    emitPosition(position ?? Duration.zero);
  }

  @override
  Future<void> dispose() => _positions.close();
}
