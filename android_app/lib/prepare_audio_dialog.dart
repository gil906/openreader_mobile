import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'offline_engine.dart';
import 'offline_narration.dart';
import 'offline_store.dart';
import 'server_narration.dart';

Future<void> showPrepareAudio(
  BuildContext context,
  OfflineDocument document,
  String voice,
) async {
  final hidden = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PrepareAudioDialog(document: document, voice: voice),
  );
  if (hidden == true && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Server work continues. Reopen Prepare entire PDF audio and tap Resume to check progress and finish downloading.',
        ),
      ),
    );
  }
}

class _PrepareAudioDialog extends StatefulWidget {
  const _PrepareAudioDialog({required this.document, required this.voice});
  final OfflineDocument document;
  final String voice;
  @override
  State<_PrepareAudioDialog> createState() => _PrepareAudioDialogState();
}

class _PrepareAudioDialogState extends State<_PrepareAudioDialog> {
  bool _running = false;
  bool _cancel = false;
  String? _error;
  NarrationProgress? _progress;
  String _generator = 'phone';
  String? _serverStatus;
  double? _serverProgress;
  bool _serverComplete = false;
  bool _serverStarted = false;
  bool _serverPending = false;
  bool _generatorChosen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restorePending());
  }

  Future<void> _restorePending() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (mounted &&
          !_running &&
          !_generatorChosen &&
          preferences.getBool(ServerNarration.pendingKey(widget.document)) ==
              true) {
        setState(() {
          _generator = 'server';
          _serverPending = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = 'Could not restore the preparation reminder: $error',
        );
      }
    }
  }

  Future<void> _prepareServer() async {
    final preferences = await SharedPreferences.getInstance();
    final configured = preferences.getString('server');
    if (configured == null || configured.isEmpty) {
      throw const ReaderException('Sign into your OpenReader server first.');
    }
    final api = OpenReaderApi(OpenReaderApi.parseServer(configured));
    try {
      if (!await api.restore()) {
        throw const ReaderException('Sign into your OpenReader server again.');
      }
      var document = widget.document.document;
      if (widget.document.importedOnPhone) {
        if (!mounted) return;
        final approved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Upload a copy to your server?'),
            content: const Text(
              'Server generation needs a copy of this PDF on your configured OpenReader server. Your phone copy stays saved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Upload copy'),
              ),
            ],
          ),
        );
        if (approved != true) return;
        final link = widget.document.metadata['narrationServerDocument'];
        if (link is Map && link['origin'] == api.base.origin) {
          document = object(link['document']);
        } else {
          document = await api.uploadPdf(
            await widget.document.pdf.readAsBytes(),
            '${document['name']}',
          );
          await widget.document.saveServerDocument(api.base.origin, document);
        }
      } else if (widget.document.origin != api.base.origin) {
        throw const ReaderException(
          'Connect to the server this PDF was saved from, or import a local copy.',
        );
      }
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      Json? payload;
      while (!_cancel && mounted) {
        final response = await api.post(
          '/api/documents/${Uri.encodeComponent(document['id'] as String)}/reader-bootstrap',
        );
        if (response['status'] == 'ready') {
          payload = object(response['payload']);
          break;
        }
        if (response['status'] == 'error' || DateTime.now().isAfter(deadline)) {
          throw const ReaderException(
            'Server PDF preparation failed or timed out. Resume later.',
          );
        }
        setState(() => _serverStatus = 'Server is preparing the PDF...');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (payload == null || _cancel || !mounted) return;
      final complete = await ServerNarration(widget.document).prepare(
        api,
        payload,
        canceled: () => _cancel || !mounted,
        onServerStarted: () async {
          if (!await preferences.setBool(
            ServerNarration.pendingKey(widget.document),
            true,
          )) {
            throw const ReaderException(
              'Server started, but its resume reminder could not be saved.',
            );
          }
          if (mounted) {
            setState(() {
              _serverStarted = true;
              _serverPending = true;
            });
          }
        },
        onProgress: (message, progress) {
          if (mounted) {
            setState(() {
              _serverStatus = message;
              _serverProgress = progress;
            });
          }
        },
      );
      if (complete) {
        if (!await preferences.setString(
          'offline-source:${widget.document.key}',
          'server',
        )) {
          throw const ReaderException(
            'Audio saved, but the playback source preference could not be saved.',
          );
        }
        if (!await preferences.remove(
          ServerNarration.pendingKey(widget.document),
        )) {
          throw const ReaderException(
            'Audio saved, but its pending reminder could not be cleared.',
          );
        }
        if (mounted) setState(() => _serverComplete = true);
      }
    } finally {
      api.close();
    }
  }

  Future<void> _prepare() async {
    setState(() {
      _running = true;
      _cancel = false;
      _serverStarted = false;
      _error = null;
    });
    final engine = OfflineVoiceEngine(
      OfflineStore(widget.document.directory.parent.parent),
    );
    var phoneWakeLock = false;
    try {
      if (_generator == 'server') {
        await _prepareServer();
        return;
      }
      await WakelockPlus.enable();
      phoneWakeLock = true;
      final narration = SavedNarration(widget.document, widget.voice);
      final progress = await narration.prepare(
        (text) => engine.synthesize(text, widget.voice),
        canceled: () => _cancel || !mounted,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (progress.complete) {
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.setString(
          'offline-source:${widget.document.key}',
          'phone',
        )) {
          throw const ReaderException(
            'Audio saved, but the playback source preference could not be saved.',
          );
        }
      }
      if (mounted) setState(() => _progress = progress);
    } catch (error) {
      if (mounted) setState(() => _error = 'Audio preparation failed: $error');
    } finally {
      await engine.close();
      if (phoneWakeLock) await WakelockPlus.disable();
      if (mounted) setState(() => _running = false);
    }
  }

  void _stop() => setState(() => _cancel = true);
  void _hide() {
    _cancel = true;
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _running) {
        if (_generator == 'server' && _serverStarted) {
          _hide();
        } else {
          _stop();
        }
      }
    },
    child: AlertDialog(
      title: const Text('Prepare entire PDF audio'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.document.document['name']}'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('preparation-generator-$_generator'),
              initialValue: _generator,
              decoration: const InputDecoration(
                labelText: 'Generate audio using',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'phone',
                  child: Text('Phone / offline voice'),
                ),
                DropdownMenuItem(
                  value: 'server',
                  child: Text('Server / save on phone'),
                ),
              ],
              onChanged: _running
                  ? null
                  : (value) => setState(() {
                      _generatorChosen = true;
                      _generator = value!;
                      _error = null;
                    }),
            ),
            const SizedBox(height: 8),
            Text(
              _generator == 'phone'
                  ? 'Voice: ${offlineVoices[widget.voice]}'
                  : 'Voice: your current server voice and blend',
            ),
            const SizedBox(height: 12),
            Text(
              _generator == 'phone'
                  ? 'Generate and permanently save all narration on this phone before reading. '
                        'Audio uses roughly 3 MB per minute and is kept until you remove it. '
                        'Keep this screen open; stopped or interrupted work can resume.'
                  : 'Generate on your server, then download the complete MP3 and PDF word timings '
                        'to this phone. Playback needs no server, internet, or voice pack. '
                        'Once the server starts, tap Hide to keep using the app. Server generation continues. '
                        'Hiding pauses downloads to this phone; reopen this screen and tap Resume to finish.',
            ),
            if (_generator == 'server' &&
                _serverPending &&
                !_running &&
                !_serverComplete)
              const Text(
                'Server audio is pending. Tap Resume to check progress and finish downloading.',
              ),
            if (_generator == 'server' && _serverStatus != null) ...[
              const SizedBox(height: 12),
              Text(_serverStatus!, key: const Key('server-audio-progress')),
            ],
            if (_generator == 'phone' && _progress != null) ...[
              const SizedBox(height: 12),
              Text(
                _progress!.complete
                    ? 'All audio saved / ready for continuous playback'
                    : '${_progress!.completed}/${_progress!.total} passages saved / '
                          '${(_progress!.bytes / 1048576).toStringAsFixed(1)} MB',
                key: const Key('prepare-audio-progress'),
              ),
              if (_progress!.separators > 0)
                Text(
                  '${_progress!.separators} non-spoken formatting markers saved as short pauses.',
                ),
            ],
            if (_running) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _generator == 'server'
                    ? _serverProgress
                    : _progress == null
                    ? null
                    : _progress!.completed / _progress!.total,
              ),
              if (_cancel)
                Text(
                  _generator == 'server'
                      ? 'Pausing this phone; server generation can continue.'
                      : 'Stopping after the current passage is saved...',
                ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        if (_running && _generator == 'server')
          TextButton(
            key: const Key('hide-server-preparation'),
            onPressed: _serverStarted ? _hide : null,
            child: const Text('Hide'),
          ),
        if (_running)
          TextButton(
            onPressed: _cancel ? null : _stop,
            child: const Text('Stop'),
          ),
        if (!_running)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        if (!_running &&
            (_generator == 'server'
                ? !_serverComplete
                : _progress?.complete != true))
          FilledButton(
            key: const Key('start-prepare-audio'),
            onPressed: _prepare,
            child: Text(
              _progress == null && !(_generator == 'server' && _serverPending)
                  ? 'Prepare all audio'
                  : 'Resume',
            ),
          ),
      ],
    ),
  );
}
