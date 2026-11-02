import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/server_narration.dart';

void main() {
  test('server preparation saves canonical timing and complete MP3 without phone voices', () async {
    final root = await Directory.systemTemp.createTemp('server-book-');
    addTearDown(() => root.delete(recursive: true));
    final payload = _payload();
    final doc = await OfflineStore(root).save(
      origin: 'https://reader.example.com',
      account: 'owner',
      document: {'id': 'demo', 'name': 'Demo.pdf'},
      payload: payload,
      bytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nsynthetic')),
    );
    final actions = <String>[];
    var network = true;
    final api = OpenReaderApi(
      Uri.parse(doc.origin),
      client: MockClient((request) async {
        if (!network) {
          throw StateError('Offline playback must not contact the server');
        }
        if (request.url.path == '/api/tts/export/resolve') {
          final body = object(jsonDecode(request.body));
          actions.add(body['action'] as String);
          expect(body['speed'], 1);
          expect(body['planObjectKey'], 'canonical-plan');
          return _json(_snapshot());
        }
        if (request.url.path.endsWith('/timeline')) {
          expect(request.url.queryParameters['rows'], 'window');
          return _json({
            'segments': [
              {
                'ordinal': 0,
                'durationMs': 1000,
                'generated': true,
                'alignment': {
                  'words': [
                    {'text': 'First', 'startSec': 0, 'endSec': 1},
                  ],
                },
              },
              {'ordinal': 1, 'durationMs': 2000, 'generated': true},
            ],
          });
        }
        return http.Response.bytes(
          [73, 68, 51, 4, 0, 0],
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      }),
    );
    addTearDown(api.close);
    final cache = ServerNarration(doc);
    expect(
      await cache.prepare(
        api,
        payload,
        canceled: () => false,
        onProgress: (_, _) {},
        pollInterval: Duration.zero,
      ),
      isTrue,
    );
    expect(actions, ['start']);
    network = false;
    final recording = (await ServerNarration(doc).load())!;
    expect(recording.voice, 'am_michael');
    expect(recording.timeline.map((row) => row['startMs']), [0, 1000]);
    expect(recording.timeline.last['endMs'], 3000);
    expect(recording.estimated, isTrue);
    expect(objects(object(recording.payload['plan'])['segments']).length, 2);
    expect(await recording.audio.length(), 6);
    expect(await OfflineStore(root).packInstalled, isFalse);
    expect(
      await cache.prepare(
        api,
        payload,
        canceled: () => false,
        onProgress: (_, _) {},
      ),
      isTrue,
    );
  });
  test(
    'server skipped readable passages cannot become a complete saved book',
    () async {
      final root = await Directory.systemTemp.createTemp('server-skipped-');
      addTearDown(() => root.delete(recursive: true));
      final doc = await OfflineStore(root).save(
        origin: 'https://reader.example.com',
        account: 'owner',
        document: {'id': 'demo', 'name': 'Demo.pdf'},
        payload: _payload(),
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nsynthetic')),
      );
      final actions = <String>[];
      final api = OpenReaderApi(
        Uri.parse(doc.origin),
        client: MockClient((request) async {
          actions.add(object(jsonDecode(request.body))['action'] as String);
          return _json(_snapshot(skipped: 1));
        }),
      );
      addTearDown(api.close);
      final cache = ServerNarration(doc);
      await expectLater(
        cache.prepare(
          api,
          _payload(),
          canceled: () => false,
          onProgress: (_, _) {},
          pollInterval: Duration.zero,
        ),
        throwsA(isA<ReaderException>()),
      );
      expect(actions, ['start', 'retry-skipped']);
      expect(await cache.load(), isNull);
    },
  );
  test('download resumes with a strong validator and rejects invalid range offsets', () async {
    final root = await Directory.systemTemp.createTemp('server-download-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/recording.mp3');
    await File('${file.path}.part').writeAsBytes([73, 68, 51]);
    await File('${file.path}.etag').writeAsString('"stable"');
    final api = OpenReaderApi(
      Uri.parse('https://reader.example.com'),
      client: MockClient((request) async {
        expect(request.headers['Range'], 'bytes=3-');
        expect(request.headers['If-Range'], '"stable"');
        return http.Response.bytes(
          [4, 0, 0],
          206,
          headers: {
            'etag': '"stable"',
            'content-range': 'bytes 3-5/6',
            'content-type': 'audio/mpeg',
          },
        );
      }),
    );
    addTearDown(api.close);
    expect(
      await api.downloadAudio(
        '/api/tts/export/download',
        file,
        canceled: () => false,
        onProgress: (_, _) {},
      ),
      isTrue,
    );
    expect(await file.readAsBytes(), [73, 68, 51, 4, 0, 0]);
    final bad = OpenReaderApi(
      Uri.parse('https://reader.example.com'),
      client: MockClient(
        (_) async => http.Response.bytes(
          [4],
          206,
          headers: {'etag': '"stable"', 'content-range': 'bytes 2-2/3'},
        ),
      ),
    );
    addTearDown(bad.close);
    await File('${file.path}.part').writeAsBytes([73, 68, 51]);
    await File('${file.path}.etag').writeAsString('"stable"');
    await expectLater(
      bad.downloadAudio(
        '/audio',
        file,
        canceled: () => false,
        onProgress: (_, _) {},
      ),
      throwsA(isA<ReaderException>()),
    );
    expect(await file.readAsBytes(), [73, 68, 51, 4, 0, 0]);
  });
}

http.Response _json(Json value) => http.Response(jsonEncode(value), 200);
Json _snapshot({int skipped = 0}) => {
  'sessionId': 'export-session',
  'generation': {'state': 'complete'},
  'progress': {
    'plannedSegments': 2,
    'completedSegments': 2 - skipped,
    'skippedSegments': skipped,
  },
  'artifact': {'state': 'ready'},
  'download': {'url': '/api/tts/export/download?artifactId=demo'},
};
Json _payload() => {
  'parsedDocument': {'pages': []},
  'plan': {
    'planId': 'plan',
    'planObjectKey': 'canonical-plan',
    'planSignature': 'signature',
    'segments': [
      {
        'ordinal': 0,
        'text': 'First paragraph',
        'locator': {'page': 1},
      },
      {
        'ordinal': 1,
        'text': 'Second paragraph',
        'locator': {'page': 2},
      },
    ],
  },
  'playback': {
    'request': {
      'documentId': 'demo',
      'settings': {'voice': 'am_michael'},
    },
  },
};
