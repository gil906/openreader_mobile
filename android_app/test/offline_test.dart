import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:openreader_native/api.dart';
import 'package:openreader_native/offline_engine.dart';
import 'package:openreader_native/offline_store.dart';
import 'package:openreader_native/playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('offline chunks preserve speech and bound long passages and tokens', () {
    final paragraph = List.filled(
      90,
      'A natural offline reading voice.',
    ).join(' ');
    final chunks = offlineChunks(paragraph);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((text) => text.length <= 280), isTrue);
    expect(chunks.join(' '), paragraph);
    expect(
      offlineChunks('a' * 900).every((text) => text.length <= 280),
      isTrue,
    );
    expect(offlineChunks('   '), isEmpty);
  });
  test('offline estimated timing retains exact source character ranges', () {
    const text = 'Read this paragraph offline, on this phone.';
    final alignment = approximateOfflineAlignment(text, 3200);
    expect(alignment['estimated'], isTrue);
    final words = objects(alignment['words']);
    expect(words.length, 7);
    for (final word in words) {
      expect(
        text.substring(integer(word['charStart']), integer(word['charEnd'])),
        word['text'],
      );
      expect(word['startSec'], greaterThanOrEqualTo(0));
      expect(word['endSec'], lessThanOrEqualTo(3.2));
    }
    expect(
      objects(approximateOfflineAlignment('Short', 10)['words'])
          .single['endSec'],
      lessThanOrEqualTo(.01),
    );
  });
  test('saved PDFs survive replacement and use opaque safe paths', () async {
    final root = await Directory.systemTemp.createTemp('reader-offline-');
    addTearDown(() => root.delete(recursive: true));
    final store = OfflineStore(root);
    final payload = <String, dynamic>{
      'parsedDocument': {'pages': []},
      'plan': {
        'segments': [
          {
            'ordinal': 0,
            'text': 'Saved text',
            'locator': {'page': 3},
          },
        ],
      },
    };
    final bytes = Uint8List.fromList(utf8.encode('%PDF-1.7\nexample'));
    final saved = await store.save(
      origin: 'http://reader.local:3003',
      account: 'owner',
      document: {'id': '../../outside', 'name': 'First.pdf'},
      payload: payload,
      bytes: bytes,
    );
    expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(saved.key), isTrue);
    await store.save(
      origin: 'http://reader.local:3003',
      account: 'owner',
      document: {'id': '../../outside', 'name': 'Updated.pdf'},
      payload: payload,
      bytes: bytes,
    );
    final restored = (await store.documents()).single;
    expect(restored.document['name'], 'Updated.pdf');
    expect(await restored.pdf.readAsBytes(), bytes);
    expect(
      objects(object(restored.payload['plan'])['segments']).single['text'],
      'Saved text',
    );
    await store.remove(restored);
    expect(await store.documents(), isEmpty);
  });
  test('corrupt voice download is rejected before installation', () async {
    final root = await Directory.systemTemp.createTemp('reader-pack-');
    addTearDown(() => root.delete(recursive: true));
    final store = OfflineStore(root);
    final file = await File('${root.path}/bad.zip').writeAsBytes([1, 2, 3]);
    await expectLater(
      store.installPack(file, (_) {}),
      throwsA(isA<ReaderException>()),
    );
    expect(await store.packInstalled, isFalse);
    final engine = OfflineVoiceEngine(store);
    await expectLater(
      engine.synthesize('Do not silently use a network voice.', 'am_michael'),
      throwsA(isA<ReaderException>()),
    );
    await engine.close();
  });
  test('saved reader preparation makes zero server calls', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final root = await Directory.systemTemp.createTemp('reader-no-network-');
    addTearDown(() => root.delete(recursive: true));
    final store = OfflineStore(root);
    final saved = await store.save(
      origin: 'http://reader.local:3003',
      account: 'owner',
      document: {'id': 'book', 'name': 'Offline.pdf'},
      payload: {
        'parsedDocument': {'pages': []},
        'plan': {
          'segments': [
            {
              'ordinal': 5,
              'text': 'This PDF is saved on the phone.',
              'locator': {'page': 3, 'blockId': 'local'},
            },
          ],
        },
        'initialPosition': {'segmentOrdinal': 5},
      },
      bytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nexample')),
    );
    var networkCalls = 0;
    final api = OpenReaderApi(
      Uri.parse(saved.origin),
      client: MockClient((_) async {
        networkCalls++;
        throw StateError('Offline reading must not use a server.');
      }),
    );
    final reader = ReaderPlayback(
      api,
      'book',
      preferences,
      offline: saved,
      audioPlayer: _IdleAudio(),
    );
    await reader.prepare();
    expect(reader.isOffline, isTrue);
    expect(reader.connected, isTrue);
    expect(reader.plan.single['text'], 'This PDF is saved on the phone.');
    expect(object(reader.plan.single['locator'])['page'], 3);
    expect(networkCalls, 0);
    await reader.close();
    api.close();
  });
}

class _IdleAudio extends Fake implements AudioPlayer {
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
