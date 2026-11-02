import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'api.dart';
import 'offline_store.dart';
import 'offline_speech.dart';

const offlineVoices = <String, String>{
  'am_michael': 'Michael / American male',
  'am_fenrir': 'Fenrir / American male',
  'am_adam': 'Adam / American male',
  'am_echo': 'Echo / American male',
  'am_eric': 'Eric / American male',
  'am_liam': 'Liam / American male',
  'am_onyx': 'Onyx / American male',
  'am_puck': 'Puck / American male',
  'am_santa': 'Santa / American male',
  'af_heart': 'Heart / American female',
  'af_bella': 'Bella / American female',
  'af_alloy': 'Alloy / American female',
  'af_aoede': 'Aoede / American female',
  'af_jessica': 'Jessica / American female',
  'af_kore': 'Kore / American female',
  'af_nicole': 'Nicole / American female',
  'af_nova': 'Nova / American female',
  'af_river': 'River / American female',
  'af_sarah': 'Sarah / American female',
  'af_sky': 'Sky / American female',
};
const _speakers = <String, int>{
  'af_alloy': 0,
  'af_aoede': 1,
  'af_bella': 2,
  'af_heart': 3,
  'af_jessica': 4,
  'af_kore': 5,
  'af_nicole': 6,
  'af_nova': 7,
  'af_river': 8,
  'af_sarah': 9,
  'af_sky': 10,
  'am_adam': 11,
  'am_echo': 12,
  'am_eric': 13,
  'am_fenrir': 14,
  'am_liam': 15,
  'am_michael': 16,
  'am_onyx': 17,
  'am_puck': 18,
  'am_santa': 19,
};

class OfflineSpeech {
  const OfflineSpeech(this.path, this.durationMs, this.alignment);
  final String path;
  final int durationMs;
  final Json alignment;
}

class OfflineVoiceEngine {
  OfflineVoiceEngine(this.store) {
    // start() forwards initialization failures; close() may run before start().
    _ready.future.ignore();
  }
  final OfflineStore store;
  final _events = ReceivePort();
  final _ready = Completer<void>();
  final _exited = Completer<void>();
  final _requests = <int, Completer<OfflineSpeech>>{};
  final _queued = <({int id, String text, String voice, bool prefetch})>[];
  final _inFlight = <String, Future<OfflineSpeech>>{};
  Isolate? _isolate;
  SendPort? _port;
  Future<void>? _starting;
  int _nextId = 0;
  int? _active;
  bool _closed = false;

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    if (!await store.packInstalled) {
      throw const ReaderException(
        'Download the offline voice pack from Offline library first.',
      );
    }
    await store.audio.create(recursive: true);
    _events.listen((message) {
      if (message == null) {
        if (!_exited.isCompleted) _exited.complete();
        if (!_closed) {
          _fail('The offline voice engine stopped. Reopen the document.');
        }
        _events.close();
        return;
      }
      if (message is List) {
        _fail('Offline voice engine error: ${message.first}');
        return;
      }
      final result = object(message);
      if (result['ready'] is SendPort) {
        _port = result['ready'] as SendPort;
        if (_closed) _port!.send({'close': true});
        if (!_ready.isCompleted) _ready.complete();
        return;
      }
      if (result['id'] == null) {
        _fail(result['error'] as String? ?? 'Unable to load offline voices.');
        return;
      }
      final id = integer(result['id']);
      final request = _requests.remove(id);
      if (request != null && !request.isCompleted) {
        if (result['error'] is String) {
          request.completeError(ReaderException(result['error'] as String));
        } else {
          request.complete(
            OfflineSpeech(
              result['path'] as String,
              integer(result['durationMs']),
              object(result['alignment']),
            ),
          );
        }
      }
      _active = null;
      _pump();
    });
    _isolate = await Isolate.spawn(
      _voiceWorker,
      {
        'reply': _events.sendPort,
        'model': store.pack.path,
        'cache': store.audio.path,
      },
      onExit: _events.sendPort,
      onError: _events.sendPort,
    );
    await _ready.future;
  }

  void _fail(String message) {
    if (_starting != null && !_ready.isCompleted) {
      _ready.completeError(ReaderException(message));
    }
    for (final request in _requests.values) {
      if (!request.isCompleted) request.completeError(ReaderException(message));
    }
    _requests.clear();
    _queued.clear();
  }

  Future<OfflineSpeech> synthesize(
    String text,
    String voice, {
    bool prefetch = false,
  }) {
    final key = '$voice\n$text';
    return _inFlight[key] ??= _generate(key, text, voice, prefetch);
  }

  Future<OfflineSpeech> _generate(
    String key,
    String text,
    String voice,
    bool prefetch,
  ) async {
    try {
      if (_closed) throw const ReaderException('Offline reader is closed.');
      if (!offlineVoices.containsKey(voice)) {
        throw const ReaderException('Unsupported offline voice.');
      }
      await start();
      if (_closed) throw const ReaderException('Offline reader is closed.');
      final id = _nextId++;
      final result = Completer<OfflineSpeech>();
      _requests[id] = result;
      _queued.add((id: id, text: text, voice: voice, prefetch: prefetch));
      _pump();
      return await result.future;
    } finally {
      _inFlight.remove(key);
    }
  }

  void _pump() {
    if (_closed || _active != null || _port == null || _queued.isEmpty) return;
    final priority = _queued.indexWhere((request) => !request.prefetch);
    final request = _queued.removeAt(priority < 0 ? 0 : priority);
    _active = request.id;
    _port!.send({
      'id': request.id,
      'text': request.text,
      'voice': request.voice,
    });
  }

  Future<void> close() async {
    _closed = true;
    _fail('Offline reader was closed.');
    if (_isolate == null) {
      _events.close();
      return;
    }
    _port?.send({'close': true});
    try {
      await _exited.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      debugPrint(
        'OpenReader: stopping an unresponsive offline synthesis worker.',
      );
      _isolate?.kill(priority: Isolate.beforeNextEvent);
    }
    _events.close();
  }
}

void _voiceWorker(Json options) {
  final reply = options['reply'] as SendPort;
  sherpa.OfflineTts? tts;
  try {
    final root = options['model'] as String;
    final cache = options['cache'] as String;
    sherpa.initBindings();
    tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: p.join(root, 'model.onnx'),
            voices: p.join(root, 'voices.bin'),
            tokens: p.join(root, 'tokens.txt'),
            dataDir: p.join(root, 'espeak-ng-data'),
            lexicon: p.join(root, 'lexicon-us-en.txt'),
            lang: 'en-us',
          ),
          numThreads: 4,
        ),
      ),
    );
    if (tts.sampleRate <= 0 || tts.numSpeakers < 20) {
      throw const ReaderException(
        'The offline Kokoro model could not be initialized.',
      );
    }
    final port = ReceivePort();
    final recent = <String>[];
    reply.send({'ready': port.sendPort});
    port.listen((message) {
      final request = object(message);
      if (request['close'] == true) {
        tts!.free();
        port.close();
        Isolate.exit();
      }
      final id = integer(request['id']);
      try {
        final text = request['text'] as String;
        final voice = request['voice'] as String;
        final hash = sha256
            .convert(utf8.encode('$offlinePackHash\nspeech-v2\n$voice\n$text'))
            .toString();
        final wav = p.join(cache, '$hash.wav');
        final metadata = File(p.join(cache, '$hash.json'));
        Json result;
        if (File(wav).existsSync() && metadata.existsSync()) {
          result = {
            ...object(jsonDecode(metadata.readAsStringSync())),
            'path': wav,
          };
        } else {
          final input = phoneSpeechInput(text);
          final sampleRate = tts!.sampleRate;
          final buffers = <Float32List>[];
          if (input.separator) {
            buffers.add(Float32List((sampleRate * .15).round()));
          } else {
            for (final part in offlineChunks(input.text, limit: 240)) {
              var audio = tts.generate(text: part, sid: _speakers[voice]!);
              if (audio.samples.isEmpty &&
                  RegExp(r'^[A-Za-z]{1,24}$').hasMatch(part)) {
                audio = tts.generate(
                  text: part.split('').join(' '),
                  sid: _speakers[voice]!,
                );
              }
              if (audio.sampleRate != sampleRate || audio.samples.isEmpty) {
                throw const ReaderException(
                  'The phone voice could not pronounce this passage. Try server generation; already saved passages are kept.',
                );
              }
              buffers.add(audio.samples);
            }
          }
          final samples = Float32List(
            buffers.fold<int>(0, (count, part) => count + part.length),
          );
          var offset = 0;
          for (final buffer in buffers) {
            samples.setRange(offset, offset + buffer.length, buffer);
            offset += buffer.length;
          }
          if (samples.isEmpty || sampleRate <= 0) {
            throw const ReaderException(
              'The phone voice returned an empty recording.',
            );
          }
          _writeWave('$wav.part', samples, sampleRate);
          File('$wav.part').renameSync(wav);
          final duration = (samples.length * 1000 / sampleRate).round();
          result = {
            'path': wav,
            'durationMs': duration,
            'alignment': input.separator
                ? {'estimated': true, 'nonSpeech': true, 'words': <Json>[]}
                : approximateOfflineAlignment(text, duration),
          };
          File('${metadata.path}.part')
              .writeAsStringSync(jsonEncode(result), flush: true);
          File('${metadata.path}.part').renameSync(metadata.path);
        }
        recent.remove(wav);
        recent.add(wav);
        File(wav).setLastModifiedSync(DateTime.now());
        if (recent.length > 2) recent.removeAt(0);
        _trimAudio(cache, recent);
        reply.send({'id': id, ...result});
      } catch (error) {
        reply.send({'id': id, 'error': 'Offline speech failed: $error'});
      }
    });
  } catch (error) {
    tts?.free();
    reply.send({'error': 'Could not load offline voices: $error'});
    Isolate.exit();
  }
}

void _trimAudio(String directory, List<String> protected) {
  final files = Directory(directory)
      .listSync()
      .whereType<File>()
      .where(
        (file) =>
            RegExp(r'^[a-f0-9]{64}\.wav$').hasMatch(p.basename(file.path)),
      )
      .toList();
  files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
  var total = files.fold<int>(0, (size, file) => size + file.lengthSync());
  for (final file in files) {
    if (total <= 256 * 1024 * 1024) break;
    if (protected.contains(file.path)) continue;
    total -= file.lengthSync();
    file.deleteSync();
    final metadata = File(file.path.replaceFirst(RegExp(r'\.wav$'), '.json'));
    if (metadata.existsSync()) metadata.deleteSync();
  }
}

void _writeWave(String filename, Float32List samples, int sampleRate) {
  final bytes = ByteData(44 + samples.length * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(
      44 + i * 2,
      (samples[i].clamp(-1, 1) * 32767).round(),
      Endian.little,
    );
  }
  File(filename).writeAsBytesSync(bytes.buffer.asUint8List(), flush: true);
}

Json approximateOfflineAlignment(String text, int durationMs) {
  final words = RegExp(r'\S+').allMatches(text).toList();
  final total = words.fold<int>(
    0,
    (sum, word) => sum + math.max(1, word.group(0)!.length),
  );
  var used = 0;
  final padding = math.min(.1, math.max(0, durationMs / 1000 * .05));
  final duration = math.max(0, durationMs / 1000 - padding * 2);
  return {
    'estimated': true,
    'words': [
      for (final word in words)
        (() {
          final start = padding + duration * used / math.max(1, total);
          used += math.max(1, word.group(0)!.length);
          return {
            'text': word.group(0),
            'charStart': word.start,
            'charEnd': word.end,
            'startSec': start,
            'endSec': padding + duration * used / math.max(1, total),
          };
        })(),
    ],
  };
}
