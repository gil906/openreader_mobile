import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'alignment.dart';
import 'api.dart';
import 'offline_engine.dart';
import 'offline_store.dart';

class ServerRecording {
  const ServerRecording(this.audio, this.payload, this.timeline, this.voice);
  final File audio;
  final Json payload;
  final List<Json> timeline;
  final String voice;
  bool get estimated =>
      timeline.any((row) => object(row['alignment'])['estimated'] == true);
}

class ServerNarration {
  ServerNarration(this.document);
  final OfflineDocument document;
  static String pendingKey(OfflineDocument document) =>
      'pending-server-audio:${document.key}';
  Directory get directory => Directory(
    p.join(
      document.directory.parent.parent.path,
      'prepared_server',
      document.key,
    ),
  );

  Future<ServerRecording?> load() async {
    final pointer = File(p.join(directory.path, 'selected.json'));
    if (!await pointer.exists()) return null;
    final profile = object(jsonDecode(await pointer.readAsString()))['profile'];
    if (profile is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(profile)) {
      throw const ReaderException('Saved server audio metadata is damaged.');
    }
    final root = Directory(p.join(directory.path, profile));
    final manifest = object(
      jsonDecode(
        await File(p.join(root.path, 'recording.json')).readAsString(),
      ),
    );
    final audio = File(p.join(root.path, 'recording.mp3'));
    final timeline = objects(manifest['timeline']);
    if (!await audio.exists() ||
        await audio.length() != integer(manifest['bytes']) ||
        timeline.isEmpty ||
        timeline.any((row) => integer(row['durationMs']) <= 0)) {
      throw const ReaderException(
        'Saved server audio is incomplete. Prepare it again.',
      );
    }
    return ServerRecording(
      audio,
      object(manifest['payload']),
      timeline,
      '${manifest['voice']}',
    );
  }

  Future<bool> prepare(
    OpenReaderApi api,
    Json payload, {
    required bool Function() canceled,
    required void Function(String message, double? progress) onProgress,
    Future<void> Function()? onServerStarted,
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    final plan = object(payload['plan']);
    final segments = objects(plan['segments']);
    final request = object(object(payload['playback'])['request']);
    if (segments.isEmpty ||
        plan['planObjectKey'] is! String ||
        request.isEmpty) {
      throw const ReaderException('The server PDF has no narration plan.');
    }
    final profile = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'origin': api.base.origin,
              'request': request,
              'planSignature': plan['planSignature'],
              'planObjectKey': plan['planObjectKey'],
            }),
          ),
        )
        .toString();
    final root = await Directory(p.join(directory.path, profile))
        .create(recursive: true);
    final audio = File(p.join(root.path, 'recording.mp3'));
    final manifestFile = File(p.join(root.path, 'recording.json'));
    if (await manifestFile.exists() && await audio.exists()) {
      final manifest = object(jsonDecode(await manifestFile.readAsString()));
      if (await audio.length() == integer(manifest['bytes'])) {
        await _write(File(p.join(directory.path, 'selected.json')), {
          'profile': profile,
        });
        onProgress('Server audio already saved / ready offline', 1);
        return true;
      }
    }
    final body = <String, dynamic>{
      ...request,
      'planId': plan['planId'],
      'planObjectKey': plan['planObjectKey'],
      'planSignature': plan['planSignature'],
      'startIntent': {'selectedOrdinal': 0},
      'format': 'mp3',
      'speed': 1,
      'includeProgress': true,
    };
    var action = 'start';
    var retried = false;
    var announced = false;
    Json snapshot = {};
    while (!canceled()) {
      snapshot = await api.post('/api/tts/export/resolve', {
        ...body,
        'action': action,
      });
      action = 'resolve';
      final generation = object(snapshot['generation']);
      final progress = object(snapshot['progress']);
      final skipped = integer(progress['skippedSegments']);
      final total = integer(progress['plannedSegments'], segments.length);
      final completed = integer(progress['completedSegments']);
      final state = generation['state'];
      onProgress(
        'Server: $completed/$total passages generated'
        '${skipped > 0 ? ' / $skipped need retry' : ''}',
        total > 0 ? completed / total : null,
      );
      if ([
        'failed',
        'stopped',
        'usage_limited',
        'interrupted',
      ].contains(state)) {
        throw ReaderException(
          'Server preparation $state. ${object(generation['issue'])['message'] ?? 'Resume later; cached passages are kept.'}',
        );
      }
      if (!announced) {
        await onServerStarted?.call();
        announced = true;
      }
      if (canceled()) return false;
      if (state == 'complete') {
        if (skipped > 0) {
          if (retried) {
            throw ReaderException(
              'The server could not pronounce $skipped passages. No incomplete recording was selected. Retry preparation.',
            );
          }
          retried = true;
          action = 'retry-skipped';
          continue;
        }
        final artifact = object(snapshot['artifact']);
        if (artifact['state'] == 'failed') {
          throw ReaderException(
            'Server audio assembly failed: ${object(artifact['issue'])['message'] ?? 'Retry preparation.'}',
          );
        }
        if (artifact['state'] == 'ready' &&
            object(snapshot['download'])['url'] is String) {
          break;
        }
        if (artifact['state'] == 'none' || artifact['state'] == 'stale') {
          action = 'start';
        }
        onProgress('Server is assembling your complete MP3...', null);
      }
      await Future<void>.delayed(pollInterval);
    }
    if (canceled()) return false;
    final rows = <Json>[];
    final sessionId = snapshot['sessionId'];
    if (sessionId is! String) {
      throw const ReaderException('Server omitted narration timing session.');
    }
    for (var start = 0; start < segments.length; start += 64) {
      if (canceled()) return false;
      onProgress(
        'Saving PDF word timings: $start/${segments.length}',
        start / segments.length,
      );
      final data = await api.get(
        '/api/tts/stream/${Uri.encodeComponent(sessionId)}/timeline?minOrdinal=$start&limit=64&rows=window',
      );
      rows.addAll(objects(data['segments']));
    }
    final byOrdinal = {for (final row in rows) integer(row['ordinal']): row};
    final timing = <Json>[];
    for (final segment in segments) {
      final row = byOrdinal[integer(segment['ordinal'])];
      final duration = integer(row?['durationMs']);
      if (row == null || row['generated'] != true || duration <= 0) {
        throw const ReaderException(
          'Server timing data is incomplete. Resume preparation before downloading.',
        );
      }
      timing.add({
        ...row,
        'locator': segment['locator'],
        'alignment': objects(object(row['alignment'])['words']).isNotEmpty
            ? row['alignment']
            : approximateOfflineAlignment('${segment['text']}', duration),
      });
    }
    final downloaded = await api.downloadAudio(
      object(snapshot['download'])['url'] as String,
      audio,
      canceled: canceled,
      onProgress: (received, total) => onProgress(
        'Saving server audio: ${(received / 1048576).toStringAsFixed(1)} MB',
        total != null && total > 0 ? received / total : null,
      ),
    );
    if (!downloaded || canceled()) return false;
    await _write(manifestFile, {
      'version': 1,
      'payload': payload,
      'timeline': mergeTimeline([], timing),
      'voice': object(request['settings'])['voice'] ?? 'Server voice',
      'bytes': await audio.length(),
    });
    await _write(File(p.join(directory.path, 'selected.json')), {
      'profile': profile,
    });
    onProgress('Server audio saved / ready for offline playback', 1);
    return true;
  }

  static Future<void> _write(File target, Json data) async {
    final temporary = File('${target.path}.part');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(target.path);
  }
}
