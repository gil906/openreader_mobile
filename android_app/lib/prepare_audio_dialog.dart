import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'offline_engine.dart';
import 'offline_narration.dart';
import 'offline_store.dart';

Future<void> showPrepareAudio(
  BuildContext context,
  OfflineDocument document,
  String voice,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PrepareAudioDialog(document: document, voice: voice),
);

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

  Future<void> _prepare() async {
    setState(() {
      _running = true;
      _cancel = false;
      _error = null;
    });
    final engine = OfflineVoiceEngine(
      OfflineStore(widget.document.directory.parent.parent),
    );
    try {
      await WakelockPlus.enable();
      final narration = SavedNarration(widget.document, widget.voice);
      final progress = await narration.prepare(
        (text) => engine.synthesize(text, widget.voice),
        canceled: () => _cancel || !mounted,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) setState(() => _progress = progress);
    } catch (error) {
      if (mounted) setState(() => _error = 'Audio preparation failed: $error');
    } finally {
      await engine.close();
      await WakelockPlus.disable();
      if (mounted) setState(() => _running = false);
    }
  }

  void _stop() => setState(() => _cancel = true);
  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _running) _stop();
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
            Text('Voice: ${offlineVoices[widget.voice]}'),
            const SizedBox(height: 12),
            const Text(
              'Generate and permanently save all narration on this phone before reading. '
              'Audio uses roughly 3 MB per minute and is kept until you remove it. '
              'Keep this screen open; stopped or interrupted work can resume.',
            ),
            if (_progress != null) ...[
              const SizedBox(height: 12),
              Text(
                _progress!.complete
                    ? 'All audio saved / ready for continuous playback'
                    : '${_progress!.completed}/${_progress!.total} passages saved / '
                          '${(_progress!.bytes / 1048576).toStringAsFixed(1)} MB',
                key: const Key('prepare-audio-progress'),
              ),
            ],
            if (_running) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _progress == null
                    ? null
                    : _progress!.completed / _progress!.total,
              ),
              if (_cancel)
                const Text('Stopping after the current passage is saved...'),
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
        if (!_running && _progress?.complete != true)
          FilledButton(
            key: const Key('start-prepare-audio'),
            onPressed: _prepare,
            child: Text(_progress == null ? 'Prepare all audio' : 'Resume'),
          ),
      ],
    ),
  );
}
