import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alignment.dart';
import 'api.dart';
import 'offline_engine.dart';
import 'offline_store.dart';
import 'offline_narration.dart';
import 'server_narration.dart';

class ReaderPlayback extends ChangeNotifier {
  ReaderPlayback(
    this.api,
    this.documentId,
    this.preferences, {
    AudioPlayer? audioPlayer,
    this.offline,
    bool? savedServerAudio,
  }) : player = audioPlayer ?? AudioPlayer() {
    _useSavedServer =
        offline != null &&
        (savedServerAudio ??
            preferences.getString('offline-source:${offline!.key}') ==
                'server');
    _offlineVoice = preferences.getString('offlineVoice') ?? 'am_michael';
    speed =
        preferences.getDouble(
          isOffline && !_useSavedServer
              ? 'offlinePlaybackSpeed'
              : 'serverPlaybackSpeed',
        ) ??
        preferences.getDouble('playbackSpeed') ??
        1;
    if (offline != null) {
      _offlineEngine = OfflineVoiceEngine(
        OfflineStore(offline!.directory.parent.parent),
      );
      _subscriptions.add(
        player.currentIndexStream.listen((_) {
          if (_closed || preparing || !_localLoaded) return;
          _updatePosition();
          unawaited(_fillOfflineQueue(_epoch));
        }),
      );
    }
    _subscriptions.add(
      player.positionStream.listen((_) {
        _updatePosition();
      }),
    );
    _subscriptions.add(
      player.playerStateStream.listen((state) {
        if (_closed || preparing) return;
        if (state.processingState == ProcessingState.completed) {
          if (isOffline && wantedPlaying) {
            if (_offlineQueue.isNotEmpty &&
                _offlineQueue.last < plan.length - 1) {
              unawaited(_resumeOfflineQueue(_epoch));
              return;
            }
          }
          wantedPlaying = false;
          status = 'Finished';
          unawaited(_tick());
        } else if (wantedPlaying && !preparing) {
          status = state.processingState == ProcessingState.buffering
              ? 'Buffering audio from your server...'
              : _readingStatus;
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.errorStream.listen((error) {
        if (preparing) return;
        _fail(const ReaderException('Audio playback failed. Tap Retry audio.'));
      }),
    );
  }

  final OpenReaderApi api;
  final String documentId;
  final SharedPreferences preferences;
  final AudioPlayer player;
  final OfflineDocument? offline;
  OfflineVoiceEngine? _offlineEngine;
  late final bool _useSavedServer;
  ServerRecording? _serverRecording;
  bool get usesSavedServer => _useSavedServer;
  late String _offlineVoice;
  bool _localLoaded = false;
  final List<int> _offlineQueue = [];
  SavedNarration? _narration;
  bool _savedNarrationComplete = false;
  Future<void>? _queueFill;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Json? payload;
  Json? _session;
  List<Json> timeline = [];
  List<Json> get plan => objects(object(payload?['plan'])['segments']);
  String status = 'Opening PDF...';
  String? error;
  bool preparing = false;
  bool wantedPlaying = false;
  bool _closed = false;
  bool _polling = false;
  bool _heartbeating = false;
  int _epoch = 0;
  int _fromOrdinal = 0;
  int _lastSaved = -1;
  int currentOrdinal = 0;
  int currentMs = 0;
  double speed = 1;
  Timer? _timer;
  Future<void> _transitions = Future<void>.value();
  HighlightWord? activeWord;

  bool get isOffline => offline != null;
  String get _readingStatus => isOffline
      ? usesSavedServer
            ? 'Saved server audio${_serverRecording!.estimated ? ' / approximate word timing' : ''}'
            : '${_savedNarrationComplete ? 'Saved narration' : 'Phone voice'} / approximate word timing'
      : 'Reading aloud';
  String get voice => usesSavedServer
      ? _serverRecording?.voice ?? 'Saved server voice'
      : isOffline
      ? offlineVoices[_offlineVoice] ?? _offlineVoice
      : object(object(payload?['playback'])['request'])['settings'] is Map
      ? object(
                  object(object(payload?['playback'])['request'])['settings'],
                )['voice']
                as String? ??
            'Server voice'
      : 'Server voice';
  int get durationMs => timeline.isEmpty ? 0 : integer(timeline.last['endMs']);
  int get readyCount =>
      timeline.where((segment) => segment['generated'] == true).length;
  bool get connected => payload != null;
  String get offlineVoice => _offlineVoice;
  String get _progressKey => usesSavedServer
      ? 'saved-server-progress:${offline!.key}'
      : '${isOffline ? 'offline-progress' : 'progress'}:${api.base.origin}:$documentId';
  String get _resumeKey => usesSavedServer
      ? 'saved-server-resume:${offline!.key}'
      : '${isOffline ? 'offline-resume' : 'resume'}:${api.base.origin}:$documentId';

  Future<void> prepare() async {
    final epoch = ++_epoch;
    try {
      if (offline != null) {
        if (usesSavedServer) {
          _serverRecording = await ServerNarration(offline!).load();
          if (_serverRecording == null) {
            throw const ReaderException(
              'Prepare server audio for this PDF first, or choose Phone / offline.',
            );
          }
          payload = _serverRecording!.payload;
          timeline = _serverRecording!.timeline;
          currentOrdinal = preferences.getInt(_progressKey) ?? 0;
          if (!plan.any((row) => row['ordinal'] == currentOrdinal)) {
            currentOrdinal = 0;
          }
          status = 'Saved server audio ready / no network needed';
          notifyListeners();
          return;
        }
        final source = offline!.payload;
        final segments = buildOfflinePlan(source);
        if (segments.isEmpty) {
          throw const ReaderException('This saved PDF has no readable text.');
        }
        payload = {
          ...source,
          'plan': {...object(source['plan']), 'segments': segments},
        };
        timeline = mergeTimeline([], [
          for (final row in segments)
            {
              'ordinal': row['ordinal'],
              'locator': row['locator'],
              'durationMs': math.max(600, (row['text'] as String).length * 65),
              'generated': false,
            },
        ]);
        final original = integer(
          object(source['initialPosition'])['segmentOrdinal'],
        );
        currentOrdinal =
            preferences.getInt(_progressKey) ??
            integer(
              segments
                  .where((row) => row['sourceOrdinal'] == original)
                  .firstOrNull?['ordinal'],
            );
        if (!segments.any((row) => row['ordinal'] == currentOrdinal)) {
          currentOrdinal = 0;
        }
        status = 'Offline PDF ready / voices run on this phone';
        notifyListeners();
        return;
      }
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      while (!_closed && epoch == _epoch) {
        final response = await api.post(
          '/api/documents/$documentId/reader-bootstrap',
        );
        if (_closed || epoch != _epoch) return;
        if (response['status'] == 'error') {
          throw ReaderException(
            response['message'] as String? ?? 'PDF preparation failed.',
          );
        }
        if (response['status'] == 'ready') {
          payload = object(response['payload']);
          timeline = objects(
            object(object(payload!['playback'])['seekLayout'])['segments'],
          );
          currentOrdinal =
              preferences.getInt(_progressKey) ??
              integer(object(payload!['initialPosition'])['segmentOrdinal']);
          if (!plan.any(
            (segment) => integer(segment['ordinal']) == currentOrdinal,
          )) {
            currentOrdinal = plan.isEmpty ? 0 : integer(plan.first['ordinal']);
          }
          status = 'Ready to read';
          notifyListeners();
          return;
        }
        final progress = object(response['progress']);
        status = progress['totalPages'] is num
            ? 'Preparing PDF: ${progress['pagesParsed'] ?? 0}/${progress['totalPages']} pages'
            : 'Server is preparing the PDF...';
        notifyListeners();
        if (DateTime.now().isAfter(deadline)) {
          throw const ReaderException(
            'PDF preparation is taking a long time. Return to the library and try again later.',
          );
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } catch (exception) {
      if (!_closed && epoch == _epoch) _fail(exception);
    }
  }

  Future<void> toggle() async {
    if (preparing || !connected) return;
    if (error != null || (isOffline ? !_localLoaded : _session == null)) {
      await startAt(currentOrdinal, resume: true);
    } else if (wantedPlaying) {
      wantedPlaying = false;
      status = 'Paused';
      await player.pause();
      await _heartbeat();
      if (!_closed) notifyListeners();
    } else {
      if (player.processingState == ProcessingState.completed) {
        await startAt(plan.isEmpty ? 0 : integer(plan.first['ordinal']));
        return;
      }
      wantedPlaying = true;
      status = _readingStatus;
      await _heartbeat();
      _play();
      if (!_closed) notifyListeners();
    }
  }

  Future<void> pause() async {
    if (preparing) {
      await _changePassage(currentOrdinal, play: false);
    } else if (wantedPlaying) {
      await toggle();
    }
  }

  void _play() {
    final epoch = _epoch;
    unawaited(
      player.play().catchError((Object exception) {
        if (!_closed && epoch == _epoch) _fail(exception);
      }),
    );
  }

  Future<void> selectAt(int ordinal) =>
      _changePassage(ordinal, play: wantedPlaying);

  Future<void> startAt(int ordinal, {bool resume = false}) =>
      _changePassage(ordinal, play: true, resume: resume);

  Future<void> _changePassage(
    int ordinal, {
    required bool play,
    bool resume = false,
  }) {
    if (_closed || payload == null) return Future<void>.value();
    if (!plan.any((segment) => integer(segment['ordinal']) == ordinal)) {
      _fail(
        const ReaderException('This passage is not available for reading.'),
      );
      return Future<void>.value();
    }
    final epoch = ++_epoch;
    _timer?.cancel();
    preparing = true;
    _localLoaded = false;
    wantedPlaying = play;
    error = null;
    activeWord = null;
    currentOrdinal = ordinal;
    currentMs = integer(
      timeline
          .where((row) => integer(row['ordinal']) == ordinal)
          .firstOrNull?['startMs'],
    );
    _fromOrdinal = ordinal;
    _lastSaved = -1;
    status = play
        ? (isOffline
              ? usesSavedServer
                    ? 'Opening saved server audio...'
                    : 'Generating natural speech on this phone...'
              : 'Preparing audio on your server...')
        : 'Passage selected / tap Listen';
    notifyListeners();
    // Interrupt an in-flight audio load before serializing session replacement.
    final stopped = player.stop();
    final task = _transitions.then(
      (_) => _startPassage(epoch, ordinal, stopped, play: play, resume: resume),
    );
    _transitions = task;
    return task;
  }

  Future<void> _startPassage(
    int epoch,
    int ordinal,
    Future<void> stopped, {
    required bool play,
    required bool resume,
  }) async {
    try {
      await stopped;
      if (_closed || epoch != _epoch) return;
      final previous = _session;
      _session = null;
      if (previous != null) {
        await _sendCursor(previous, ordinal: ordinal, active: false);
      }
      if (_closed || epoch != _epoch) return;
      if (!resume) await _savePosition(ordinal, 0);
      if (_closed || epoch != _epoch) return;
      if (!play) {
        preparing = false;
        notifyListeners();
        return;
      }
      if (isOffline) {
        await _startOffline(epoch, ordinal, resume: resume);
        return;
      }
      final request = object(object(payload!['playback'])['request']);
      final planData = object(payload!['plan']);
      final session = await api.post('/api/tts/stream/sessions', {
        ...request,
        'planId': planData['planId'],
        'planObjectKey': planData['planObjectKey'],
        'planSignature': planData['planSignature'],
        'startIntent': {'selectedOrdinal': ordinal},
        'generationExtent': 'window',
      });
      if (_closed || epoch != _epoch) {
        await _sendCursor(session, ordinal: ordinal, active: false);
        return;
      }
      if (session['sessionId'] is! String ||
          session['sessionInstanceId'] is! String ||
          session['audioUrl'] is! String) {
        throw const ReaderException('Unsupported server playback response.');
      }
      _session = session;
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        unawaited(_tick());
      });
      await _sendCursor(session, ordinal: ordinal, active: true);
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      while (!_closed && epoch == _epoch) {
        await _refreshTimeline();
        if (_closed || epoch != _epoch) return;
        final segment = timeline
            .where((row) => integer(row['ordinal']) == ordinal)
            .firstOrNull;
        if (segment?['audioState'] == 'error' ||
            segment?['audioState'] == 'failed') {
          throw const ReaderException(
            'The server could not generate this audio.',
          );
        }
        if (segment?['generated'] == true) {
          break;
        }
        status =
            'Preparing audio... $readyCount/${timeline.length} segments cached';
        notifyListeners();
        if (DateTime.now().isAfter(deadline)) {
          throw const ReaderException(
            'Audio generation timed out. Your server may be busy. Tap Retry audio.',
          );
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (_closed || epoch != _epoch) return;
      final uri = Uri.parse(session['audioUrl'] as String);
      if (!['http', 'https'].contains(uri.scheme)) {
        throw const ReaderException(
          'The server returned an invalid audio URL.',
        );
      }
      final url = uri.replace(
        queryParameters: {...uri.queryParameters, 'fromOrdinal': '$ordinal'},
      );
      await player.setUrl(url.toString()).timeout(const Duration(minutes: 2));
      if (_closed || epoch != _epoch) return;
      await player.setSpeed(speed);
      if (resume) {
        final offset = preferences.getInt(_resumeKey) ?? 0;
        final row = timeline
            .where((row) => integer(row['ordinal']) == ordinal)
            .firstOrNull;
        if (offset > 0 && offset < integer(row?['durationMs']) - 500) {
          await player.seek(Duration(milliseconds: offset));
        }
      }
      preparing = false;
      status = 'Reading aloud';
      notifyListeners();
      _play();
    } catch (exception) {
      if (!_closed && epoch == _epoch) _fail(exception);
    }
  }

  Future<void> _startOffline(
    int epoch,
    int ordinal, {
    required bool resume,
  }) async {
    if (usesSavedServer) {
      _offlineQueue.clear();
      final row = timeline
          .where((row) => integer(row['ordinal']) == ordinal)
          .first;
      final offset = resume ? preferences.getInt(_resumeKey) ?? 0 : 0;
      final position =
          integer(row['startMs']) +
          (offset >= 0 && offset < integer(row['durationMs']) ? offset : 0);
      await player.setFilePath(
        _serverRecording!.audio.path,
        initialPosition: Duration(milliseconds: position),
      );
      if (_closed || epoch != _epoch) return;
      await player.setSpeed(speed);
      _localLoaded = true;
      preparing = false;
      status = _readingStatus;
      notifyListeners();
      _play();
      return;
    }
    if (_queueFill != null) await _queueFill;
    if (_closed || epoch != _epoch) return;
    _narration = SavedNarration(offline!, _offlineVoice);
    final saved = await _narration!.progress();
    _savedNarrationComplete = saved.complete;
    timeline = mergeTimeline([], [
      for (final row in plan)
        {
          'ordinal': row['ordinal'],
          'locator': row['locator'],
          'durationMs': saved.durations[integer(row['ordinal'])] > 0
              ? saved.durations[integer(row['ordinal'])]
              : math.max(600, (row['text'] as String).length * 65),
          'generated': saved.durations[integer(row['ordinal'])] > 0,
        },
    ]);
    final sources = <AudioSource>[];
    _offlineQueue.clear();
    for (
      var index = ordinal;
      index < plan.length && index < ordinal + 2;
      index++
    ) {
      final speech = await _offlineAudio(index);
      if (_closed || epoch != _epoch) return;
      _includeOfflineTiming(index, speech);
      _offlineQueue.add(index);
      sources.add(AudioSource.uri(Uri.file(speech.path)));
    }
    if (_closed || epoch != _epoch) return;
    final duration = integer(timeline[ordinal]['durationMs']);
    final offset = resume ? preferences.getInt(_resumeKey) ?? 0 : 0;
    await player.setAudioSources(
      sources,
      initialIndex: 0,
      initialPosition: Duration(
        milliseconds: offset > 0 && offset < duration - 300 ? offset : 0,
      ),
    );
    if (_closed || epoch != _epoch) return;
    await player.setSpeed(speed);
    _localLoaded = true;
    preparing = false;
    status = _readingStatus;
    notifyListeners();
    _play();
    unawaited(_fillOfflineQueue(epoch));
  }

  Future<OfflineSpeech> _offlineAudio(int ordinal) async {
    final saved = await _narration!.load(ordinal);
    if (saved != null) return saved;
    if (_savedNarrationComplete) {
      throw const ReaderException(
        'Saved narration is missing a passage. Resume Prepare entire PDF audio from Offline library.',
      );
    }
    return _offlineEngine!.synthesize(
      plan[ordinal]['text'] as String,
      _offlineVoice,
    );
  }

  void _includeOfflineTiming(int ordinal, OfflineSpeech speech) {
    timeline = mergeTimeline(timeline, [
      {
        'ordinal': ordinal,
        'durationMs': speech.durationMs,
        'generated': true,
        'alignment': speech.alignment,
        'locator': plan[ordinal]['locator'],
      },
    ]);
  }

  Future<void> _fillOfflineQueue(int epoch) {
    if (_queueFill != null) return _queueFill!;
    final finished = Completer<void>();
    _queueFill = finished.future;
    _fillQueue(epoch).then(
      (_) {
        _queueFill = null;
        finished.complete();
      },
      onError: (Object error, StackTrace stack) {
        _queueFill = null;
        finished.completeError(error, stack);
      },
    );
    return finished.future;
  }

  Future<void> _fillQueue(int epoch) async {
    try {
      while (!_closed &&
          epoch == _epoch &&
          _offlineQueue.isNotEmpty &&
          _offlineQueue.last < plan.length - 1 &&
          _offlineQueue.length - (player.currentIndex ?? 0) <
              (_savedNarrationComplete ? 8 : 4)) {
        final next = _offlineQueue.last + 1;
        final speech = await _offlineAudio(next);
        if (_closed || epoch != _epoch) return;
        _includeOfflineTiming(next, speech);
        _offlineQueue.add(next);
        await player.addAudioSource(AudioSource.uri(Uri.file(speech.path)));
      }
    } catch (error) {
      if (!_closed && epoch == _epoch) _fail(error);
    }
  }

  Future<void> _resumeOfflineQueue(int epoch) async {
    final previousLength = _offlineQueue.length;
    status = 'Preparing the next phone audio...';
    notifyListeners();
    await _fillOfflineQueue(epoch);
    if (_closed || epoch != _epoch || !wantedPlaying || error != null) return;
    if (_offlineQueue.length > previousLength) {
      if ((player.currentIndex ?? 0) < previousLength) {
        await player.seek(Duration.zero, index: previousLength);
      }
      _play();
    }
  }

  Future<void> setOfflineVoice(String value) async {
    if (!isOffline || usesSavedServer || !offlineVoices.containsKey(value)) {
      _fail(const ReaderException('This offline voice is unavailable.'));
      return;
    }
    _offlineVoice = value;
    if (!await preferences.setString('offlineVoice', value)) {
      _fail(const ReaderException('Could not save your offline voice.'));
      return;
    }
    await selectAt(currentOrdinal);
  }

  Future<void> _refreshTimeline() async {
    if (_session == null || _polling || _closed) return;
    _polling = true;
    final session = _session!;
    try {
      final uri = Uri.parse(session['timelineUrl'] as String);
      final data = await api.get(
        uri
            .replace(
              queryParameters: {
                ...uri.queryParameters,
                'minOrdinal': '${math.max(0, currentOrdinal - 1)}',
                'limit': '8',
                'rows': 'window',
              },
            )
            .toString(),
      );
      if (!_closed && identical(_session, session)) {
        if (data['status'] == 'canceled') {
          throw const ReaderException(
            'This audio was cleared. Tap Retry audio.',
          );
        }
        timeline = mergeTimeline(timeline, objects(data['segments']));
        _updatePosition();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _tick() async {
    final epoch = _epoch;
    try {
      await _heartbeat();
      if (wantedPlaying) await _refreshTimeline();
    } catch (exception) {
      if (!_closed && epoch == _epoch) _fail(exception);
    }
  }

  Future<void> _heartbeat({bool? active}) async {
    if (_session == null || _heartbeating) return;
    final session = _session!;
    _heartbeating = true;
    try {
      await _sendCursor(
        session,
        ordinal: currentOrdinal,
        active: active ?? wantedPlaying,
      );
    } finally {
      _heartbeating = false;
    }
  }

  Future<void> _sendCursor(
    Json session, {
    required int ordinal,
    required bool active,
  }) => api
      .post(
        '/api/tts/stream/${Uri.encodeComponent(session['sessionId'] as String)}/cursor',
        {
          'ordinal': ordinal,
          'playbackActive': active,
          'sessionInstanceId': session['sessionInstanceId'],
        },
      )
      .then((_) {});

  Future<void> _savePosition(int ordinal, int offset) async {
    final results = await Future.wait([
      preferences.setInt(_progressKey, ordinal),
      preferences.setInt(_resumeKey, offset),
    ]);
    if (results.any((saved) => !saved)) {
      throw const ReaderException('Unable to save your reading position.');
    }
  }

  void _updatePosition() {
    if (_closed || (_session == null && !_localLoaded) || preparing) return;
    if (isOffline && _offlineQueue.isNotEmpty) {
      final index = player.currentIndex ?? 0;
      if (index >= 0 && index < _offlineQueue.length) {
        _fromOrdinal = _offlineQueue[index];
      }
    }
    final origin = timeline
        .where((row) => integer(row['ordinal']) == _fromOrdinal)
        .firstOrNull;
    currentMs =
        (usesSavedServer ? 0 : integer(origin?['startMs'])) +
        player.position.inMilliseconds;
    final current = isOffline && !usesSavedServer
        ? origin
        : timeline
              .where(
                (row) =>
                    currentMs >= integer(row['startMs']) &&
                    currentMs < integer(row['endMs']),
              )
              .firstOrNull;
    if (current != null) currentOrdinal = integer(current['ordinal']);
    activeWord = wordAt(timeline, currentMs);
    if ((_session != null || _localLoaded) &&
        !preparing &&
        currentMs ~/ 2000 != _lastSaved) {
      _lastSaved = currentMs ~/ 2000;
      unawaited(
        _savePosition(
          currentOrdinal,
          math.max(0, currentMs - integer(current?['startMs'])),
        ).catchError((Object exception) {
          if (!_closed) {
            _fail(
              const ReaderException('Unable to save your reading position.'),
            );
          }
        }),
      );
    }
    notifyListeners();
  }

  Future<void> setSpeed(double value) async {
    try {
      await player.setSpeed(value);
      speed = value;
      await preferences.setDouble(
        isOffline && !usesSavedServer
            ? 'offlinePlaybackSpeed'
            : 'serverPlaybackSpeed',
        value,
      );
      if (!_closed) notifyListeners();
    } catch (exception) {
      if (!_closed) _fail(exception);
    }
  }

  void _fail(Object exception) {
    if (_closed) return;
    wantedPlaying = false;
    preparing = false;
    _timer?.cancel();
    error = exception is ReaderException
        ? exception.message
        : isOffline
        ? 'Offline audio could not be loaded on this phone. Reopen the PDF or reinstall the voice pack.'
        : exception is TimeoutException
        ? 'Server connection timed out. Check Wi-Fi and that the Lenovo is awake.'
        : 'Could not reach OpenReader. Check your connection and retry.';
    status = error!;
    unawaited(player.pause());
    notifyListeners();
  }

  Future<void> close() async {
    _closed = true;
    _epoch++;
    _timer?.cancel();
    await player.stop();
    await _offlineEngine?.close();
    if (_queueFill != null) await _queueFill;
    await _transitions;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _heartbeat(active: false);
    } catch (exception) {
      debugPrint('OpenReader: unable to release playback: $exception');
    }
    await player.dispose();
    super.dispose();
  }
}
