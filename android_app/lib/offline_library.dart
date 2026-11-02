import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'offline_engine.dart';
import 'offline_store.dart';
import 'reader.dart';
import 'offline_narration.dart';
import 'prepare_audio_dialog.dart';
import 'server_narration.dart';

class OfflineLibraryPage extends StatefulWidget {
  const OfflineLibraryPage({super.key, required this.preferences});
  final SharedPreferences preferences;
  @override
  State<OfflineLibraryPage> createState() => _OfflineLibraryPageState();
}

class _OfflineLibraryPageState extends State<OfflineLibraryPage> {
  OfflineStore? _store;
  List<OfflineDocument> _documents = [];
  Map<String, NarrationProgress> _narrations = {};
  Set<String> _serverRecordings = {};
  bool _installed = false;
  bool _busy = true;
  bool _downloading = false;
  bool _canceled = false;
  bool _error = false;
  String? _message;
  double? _progress;
  http.Client? _download;
  late String _voice;

  @override
  void initState() {
    super.initState();
    _voice = widget.preferences.getString('offlineVoice') ?? 'am_michael';
    unawaited(_refresh());
  }

  void _status(String message, {bool error = false}) {
    if (mounted) {
      setState(() {
        _message = message;
        _error = error;
      });
    }
  }

  Future<void> _refresh() async {
    try {
      _store ??= await OfflineStore.open();
      final documents = await _store!.documents();
      final installed = await _store!.packInstalled;
      final narrations = <String, NarrationProgress>{};
      final serverRecordings = <String>{};
      for (final document in documents) {
        narrations[document.key] = await SavedNarration(
          document,
          _voice,
        ).progress();
        if (await ServerNarration(document).load() != null) {
          serverRecordings.add(document.key);
        }
      }
      if (mounted) {
        setState(() {
          _documents = documents;
          _installed = installed;
          _narrations = narrations;
          _serverRecordings = serverRecordings;
        });
      }
    } catch (error) {
      _status('Could not open offline storage: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadPack() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download natural offline voices'),
        content: const Text(
          'Download the full-quality Kokoro English pack (about 350 MB) over home Wi-Fi. '
          'After installation, saved PDFs and imported PDFs can be read with no server '
          'or internet. Allow roughly 1 GB of free storage during installation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _downloading = true;
      _canceled = false;
      _progress = null;
    });
    File? partial;
    final client = http.Client();
    _download = client;
    try {
      _store ??= await OfflineStore.open();
      final configured = widget.preferences.getString('server');
      final uri = configured == null || configured.isEmpty
          ? Uri.parse(
              'https://github.com/gil906/openreader_mobile/releases/download/v1.2.0/$offlinePackName',
            )
          : Uri(
              scheme: 'http',
              host: OpenReaderApi.parseServer(configured).host,
              port: 3005,
              path: '/$offlinePackName',
            );
      _status('Downloading the verified Kokoro voice pack...');
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw ReaderException(
          'Voice download returned HTTP ${response.statusCode}.',
        );
      }
      partial = File(p.join(_store!.root.path, 'voices.zip.part'));
      final output = partial.openWrite();
      var received = 0;
      var flushed = 0;
      var lastUpdate = 0;
      try {
        await for (final bytes in response.stream.timeout(
          const Duration(seconds: 45),
        )) {
          if (_canceled) throw const ReaderException('Download canceled.');
          received += bytes.length;
          if (received > 600 * 1024 * 1024) {
            throw const ReaderException(
              'Voice pack exceeds its expected size.',
            );
          }
          output.add(bytes);
          if (received - flushed >= 4 * 1024 * 1024) {
            await output.flush();
            flushed = received;
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          if (mounted && now - lastUpdate >= 200) {
            lastUpdate = now;
            setState(() {
              _progress = response.contentLength == null
                  ? null
                  : received / response.contentLength!;
              _message =
                  'Downloading voices: ${(received / 1048576).toStringAsFixed(0)} MB';
            });
          }
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (_canceled) throw const ReaderException('Download canceled.');
      if (mounted) {
        setState(() {
          _progress = null;
          _downloading = false;
        });
      }
      await _store!.installPack(partial, _status);
      _status('Offline voices are installed. Speech now runs on your phone.');
      await _refresh();
    } catch (error) {
      _status(
        _canceled
            ? 'Download canceled. No incomplete voice pack was installed.'
            : 'Voice installation failed: $error',
        error: !_canceled,
      );
    } finally {
      client.close();
      _download = null;
      if (partial != null && await partial.exists()) await partial.delete();
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _import() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (picked.isEmpty) return;
      final selected = picked.single;
      if (selected.path == null) {
        throw const ReaderException('Android did not provide a readable PDF.');
      }
      final source = File(selected.path!);
      if (await source.length() > 100 * 1024 * 1024) {
        throw const ReaderException('Local import supports PDFs up to 100 MB.');
      }
      if (mounted) setState(() => _busy = true);
      _status('Importing PDF and extracting its readable text...');
      _store ??= await OfflineStore.open();
      await _store!.importPdf(await source.readAsBytes(), selected.name);
      _status('PDF saved on this phone.');
      await _refresh();
    } catch (error) {
      _status('PDF import failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(OfflineDocument document) async {
    final api = OpenReaderApi(Uri.parse(document.origin));
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            api: api,
            preferences: widget.preferences,
            document: document.document,
            offline: document,
          ),
        ),
      );
    } finally {
      api.close();
    }
  }

  Future<void> _remove(OfflineDocument document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove saved copy?'),
        content: Text(
          '${document.document['name']}\n\nOnly this phone copy is removed. Your server PDF is not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _store!.remove(document);
      await _refresh();
    } catch (error) {
      _status('Could not remove the saved copy: $error', error: true);
    }
  }

  Future<void> _selectVoice(String? value) async {
    if (value == null) return;
    if (!await widget.preferences.setString('offlineVoice', value)) {
      _status('Could not save your offline voice.', error: true);
      return;
    }
    if (mounted) setState(() => _voice = value);
    await _refresh();
  }

  Future<void> _prepareDocument(OfflineDocument document) async {
    setState(() => _busy = true);
    try {
      await showPrepareAudio(context, document, _voice);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeNarration(OfflineDocument document) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove saved narration?'),
        content: const Text(
          'This removes all prepared voices for this PDF. The PDF itself remains saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove audio'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    try {
      final directory = Directory(
        p.join(_store!.root.path, 'prepared', document.key),
      );
      if (await directory.exists()) await directory.delete(recursive: true);
      final serverDirectory = ServerNarration(document).directory;
      if (await serverDirectory.exists()) {
        await serverDirectory.delete(recursive: true);
      }
      if (!await widget.preferences.remove(
        ServerNarration.pendingKey(document),
      )) {
        throw const ReaderException(
          'Audio removed, but the server preparation reminder could not be cleared.',
        );
      }
      if (!await widget.preferences.remove('offline-source:${document.key}')) {
        throw const ReaderException(
          'Audio removed, but the source preference could not be cleared.',
        );
      }
      await _refresh();
    } catch (error) {
      _status('Could not remove saved narration: $error', error: true);
    }
  }

  @override
  void dispose() {
    _canceled = true;
    _download?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy || _downloading,
    child: Scaffold(
      appBar: AppBar(title: const Text('Offline library')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Voices on this phone',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _installed
                        ? 'Kokoro is ready. No server, internet, or Android system voice is used.'
                        : 'Install natural Kokoro voices once over home Wi-Fi.',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('offline-voice-$_voice'),
                    initialValue: _voice,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Offline voice',
                    ),
                    items: [
                      for (final voice in offlineVoices.entries)
                        DropdownMenuItem(
                          value: voice.key,
                          child: Text(
                            voice.value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _busy ? null : _selectVoice,
                  ),
                  const SizedBox(height: 12),
                  if (!_installed)
                    FilledButton.icon(
                      key: const Key('download-offline-pack'),
                      onPressed: _busy ? null : _downloadPack,
                      icon: const Icon(Icons.download),
                      label: const Text('Download offline voices'),
                    ),
                  if (_installed)
                    const Text('20 English voices / full-quality model'),
                  if (_installed)
                    TextButton(
                      onPressed: _busy ? null : _downloadPack,
                      child: const Text('Reinstall voice pack'),
                    ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress),
                  ],
                  if (_downloading)
                    TextButton(
                      onPressed: () {
                        _canceled = true;
                        _download?.close();
                      },
                      child: const Text('Cancel download'),
                    ),
                ],
              ),
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _error ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: const Key('offline-import'),
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import a PDF from this phone'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Or open a server PDF and choose Save for offline. Saved PDFs and voices '
              'stay in private app storage. Local scanned PDFs need OCR first. '
              'Offline word timing is approximate; online timing is unchanged.',
            ),
          ),
          if (_documents.isEmpty && !_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No saved PDFs yet.', textAlign: TextAlign.center),
            ),
          for (final document in _documents)
            Card(
              child: ListTile(
                key: Key('offline-document-${document.key}'),
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: Text(
                  '${document.document['name']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  _serverRecordings.contains(document.key)
                      ? 'PDF + server voice saved / ready offline'
                      : widget.preferences.getBool(
                              ServerNarration.pendingKey(document),
                            ) ==
                            true
                      ? 'Server audio pending / reopen preparation to resume'
                      : _narrations[document.key]?.complete == true
                      ? 'PDF + all ${offlineVoices[_voice]?.split(' / ').first} audio saved'
                      : '${_narrations[document.key]?.completed ?? 0}/${_narrations[document.key]?.total ?? 0} audio passages saved',
                ),
                onTap: _busy ? null : () => _open(document),
                trailing: PopupMenuButton<String>(
                  key: Key('offline-options-${document.key}'),
                  enabled: !_busy,
                  onSelected: (value) {
                    if (value == 'prepare') _prepareDocument(document);
                    if (value == 'audio') _removeNarration(document);
                    if (value == 'remove') _remove(document);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'prepare',
                      enabled: buildOfflinePlan(document.payload).isNotEmpty,
                      child: const Text('Prepare entire PDF audio'),
                    ),
                    const PopupMenuItem(
                      value: 'audio',
                      child: Text('Remove saved narration'),
                    ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove saved PDF'),
                    ),
                  ],
                ),
              ),
            ),
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'OpenReader Native',
            ),
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    ),
  );
}
