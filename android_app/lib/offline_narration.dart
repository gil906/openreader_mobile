import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'offline_engine.dart';
import 'offline_store.dart';

class NarrationProgress {
  const NarrationProgress(this.total, this.durations, this.sizes);
  final int total;
  final List<int> durations;
  final List<int> sizes;
  int get completed => durations.where((value) => value > 0).length;
  bool get complete => total > 0 && completed == total;
  int get bytes => sizes.fold(0, (a, b) => a + b);
}

class SavedNarration {
  SavedNarration(this.document, this.voice) {
    if (!offlineVoices.containsKey(voice) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(document.key)) {
      throw const ReaderException('Invalid saved narration voice or document.');
    }
    plan = buildOfflinePlan(document.payload);
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'model': offlinePackHash,
              'voice': voice,
              'segments': [
                for (final row in plan)
                  {'text': row['text'], 'locator': row['locator']},
              ],
            }),
          ),
        )
        .toString();
    directory = Directory(
      p.join(
        document.directory.parent.parent.path,
        'prepared',
        document.key,
        fingerprint,
      ),
    );
  }
  final OfflineDocument document;
  final String voice;
  late final List<Json> plan;
  late final Directory directory;
  File _wave(int ordinal) => File(p.join(directory.path, '$ordinal.wav'));
  File _metadata(int ordinal) => File(p.join(directory.path, '$ordinal.json'));

  Future<NarrationProgress> progress() async {
    final file = File(p.join(directory.path, 'progress.json'));
    if (!await file.exists()) {
      return NarrationProgress(
        plan.length,
        List.filled(plan.length, 0),
        List.filled(plan.length, 0),
      );
    }
    final json = object(jsonDecode(await file.readAsString()));
    List<int> values(String key) {
      final list = json[key];
      if (list is! List || list.length != plan.length) {
        throw const ReaderException(
          'Saved narration metadata is incomplete. Remove its audio and prepare it again.',
        );
      }
      return list.map((value) => integer(value)).toList();
    }

    return NarrationProgress(plan.length, values('durations'), values('sizes'));
  }

  Future<OfflineSpeech?> load(int ordinal) async {
    if (ordinal < 0 || ordinal >= plan.length) {
      throw const ReaderException('Invalid saved narration passage.');
    }
    final wave = _wave(ordinal);
    final metadata = _metadata(ordinal);
    if (!await wave.exists() || !await metadata.exists()) return null;
    final json = object(jsonDecode(await metadata.readAsString()));
    if (integer(json['durationMs']) <= 0 || await wave.length() <= 44) {
      throw const ReaderException(
        'A saved audio passage is damaged. Remove its audio and prepare it again.',
      );
    }
    return OfflineSpeech(
      wave.path,
      integer(json['durationMs']),
      object(json['alignment']),
    );
  }

  Future<NarrationProgress> prepare(
    Future<OfflineSpeech> Function(String text) generate, {
    required bool Function() canceled,
    required void Function(NarrationProgress) onProgress,
  }) async {
    if (plan.isEmpty) {
      throw const ReaderException('This PDF has no readable text.');
    }
    await directory.create(recursive: true);
    var status = await progress();
    onProgress(status);
    for (var ordinal = 0; ordinal < plan.length; ordinal++) {
      if (canceled()) break;
      var speech = await load(ordinal);
      if (speech == null) {
        speech = await generate(plan[ordinal]['text'] as String);
        final wave = _wave(ordinal);
        final partial = File('${wave.path}.part');
        try {
          await File(speech.path).copy(partial.path);
          await partial.rename(wave.path);
          await _writeJson(_metadata(ordinal), {
            'durationMs': speech.durationMs,
            'alignment': speech.alignment,
          });
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
      status.durations[ordinal] = speech.durationMs;
      status.sizes[ordinal] = await _wave(ordinal).length();
      await _writeJson(File(p.join(directory.path, 'progress.json')), {
        'voice': voice,
        'model': offlinePackHash,
        'durations': status.durations,
        'sizes': status.sizes,
      });
      onProgress(status);
    }
    return status;
  }

  static Future<void> _writeJson(File target, Json json) async {
    final temporary = File('${target.path}.part');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(target.path);
  }
}
