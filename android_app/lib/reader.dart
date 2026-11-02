import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api.dart';
import 'passages.dart';
import 'playback.dart';
import 'offline_store.dart';
import 'offline_engine.dart';
import 'prepare_audio_dialog.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.api,
    required this.preferences,
    required this.document,
    this.offline,
  });
  final OpenReaderApi api;
  final SharedPreferences preferences;
  final Json document;
  final OfflineDocument? offline;
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _PageHighlight {
  const _PageHighlight(this.page, this.rects, [this.word]);
  final int page;
  final List<PdfRect> rects;
  final String? word;
}

class _ReaderPageState extends State<ReaderPage> {
  final _viewer = PdfViewerController();
  final _highlight = ValueNotifier<_PageHighlight?>(null);
  final Map<int, PdfPageRawText?> _texts = {};
  final Set<int> _loadingText = {};
  late ReaderPlayback _playback;
  OfflineDocument? _savedDocument;
  Json? _serverDocument;
  final List<OpenReaderApi> _ownedApis = [];
  bool _switchingSource = false;
  Widget? _pdfWidget;
  Uint8List? _pdfBytes;
  String? _pdfError;
  int _page = 1;
  int _pageCount = 0;
  bool _follow = true;
  bool? _transcript;
  bool _awake = false;
  bool _positionRestored = false;
  bool _fullscreen = false;
  bool _pdfDark = false;
  bool _changingFullscreen = false;
  bool _savingOffline = false;
  static const _window = MethodChannel('com.homelab.openreader_native/reader');
  static const _darkPageColors = ColorFilter.matrix([
    -0.88,
    0,
    0,
    0,
    247,
    0,
    -0.88,
    0,
    0,
    249,
    0,
    0,
    -0.88,
    0,
    253,
    0,
    0,
    0,
    1,
    0,
  ]);
  String _wordSignature = '';
  bool get _transcriptVisible =>
      !_fullscreen &&
      (_transcript ?? (MediaQuery.sizeOf(context).width >= 700));

  @override
  void initState() {
    super.initState();
    _pdfDark = widget.preferences.getBool('pdfDarkMode') ?? false;
    _savedDocument = widget.offline;
    _playback = ReaderPlayback(
      widget.api,
      widget.document['id'] as String,
      widget.preferences,
      offline: widget.offline,
    )..addListener(_onPlayback);
    unawaited(_open());
  }

  Future<void> _open() async {
    unawaited(_playback.prepare());
    await _downloadPdf();
  }

  Future<void> _downloadPdf() async {
    if (mounted) setState(() => _pdfError = null);
    try {
      final bytes = widget.offline == null
          ? await widget.api.pdf(widget.document['id'] as String)
          : await widget.offline!.pdf.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pdfBytes = bytes;
        _pdfWidget = _createPdf(bytes);
      });
    } catch (exception) {
      if (mounted) {
        setState(() {
          _pdfError = exception is ReaderException
              ? exception.message
              : widget.offline != null
              ? 'The saved PDF could not be read. Remove this phone copy and save or import it again.'
              : 'PDF download failed. Check your connection and retry.';
        });
      }
    }
  }

  Widget _createPdf(Uint8List bytes) => PdfViewer.data(
    bytes,
    sourceName: widget.document['id'] as String,
    controller: _viewer,
    params: PdfViewerParams(
      sizeDelegateProvider: const PdfViewerSizeDelegateProviderSmart(),
      backgroundColor: _pdfDark ? const Color(0xff111315) : Colors.grey,
      pageImageColorFilter: _pdfDark ? _darkPageColors : null,
      onGeneralTap: (context, controller, details) {
        if (details.type != PdfViewerGeneralTapType.tap ||
            !_playback.connected) {
          return false;
        }
        final hit = controller.getPdfPageHitTestResult(
          details.documentPosition,
          useDocumentLayoutCoordinates: true,
        );
        if (hit == null) return false;
        final native = _texts[hit.page.pageNumber];
        final passage = passageAtPoint(
          page: hit.page.pageNumber,
          point: Offset(hit.offset.x, hit.page.height - hit.offset.y),
          pages: objects(object(_playback.payload?['parsedDocument'])['pages']),
          plan: _playback.plan,
          pageText: native?.fullText,
          characterRects: native?.charRects
              .map((rect) => rect.toRect(page: hit.page))
              .toList(),
        );
        if (passage == null) return false;
        setState(() => _follow = true);
        unawaited(_playback.selectAt(integer(passage['ordinal'])));
        return true;
      },
      onViewerReady: (document, controller) {
        if (!mounted) return;
        setState(() => _pageCount = document.pages.length);
        _restorePage();
      },
      onPageChanged: (page) {
        if (!mounted || page == null) return;
        setState(() => _page = page);
        unawaited(_loadText(page));
      },
      pageOverlaysBuilder: (context, rect, page) => [
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<_PageHighlight?>(
              valueListenable: _highlight,
              builder: (context, value, _) => Semantics(
                key: value?.page == page.pageNumber && value?.word != null
                    ? const Key('pdf-spoken-word')
                    : null,
                label: value?.page == page.pageNumber && value?.word != null
                    ? 'Reading ${value!.word}'
                    : null,
                child: CustomPaint(painter: _WordPainter(page, _highlight)),
              ),
            ),
          ),
        ),
      ],
      errorBannerBuilder: (context, error, stack, document) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This PDF could not be opened by the native renderer.'),
        ),
      ),
    ),
  );

  Future<void> _loadText(int page) async {
    if (!_viewer.isReady ||
        _texts.containsKey(page) ||
        !_loadingText.add(page) ||
        page < 1 ||
        page > _viewer.pageCount) {
      return;
    }
    try {
      final text = await _viewer.pages[page - 1].loadText();
      if (!mounted) return;
      _texts[page] = text;
      _wordSignature = '';
      _paintWord();
    } catch (exception) {
      debugPrint(
        'OpenReader: native PDF text unavailable on page $page: $exception',
      );
    } finally {
      _loadingText.remove(page);
    }
  }

  void _onPlayback() {
    if (!mounted) return;
    final awake = _playback.wantedPlaying;
    if (awake != _awake) {
      _awake = awake;
      unawaited(
        WakelockPlus.toggle(enable: awake).catchError((Object error) {
          debugPrint('OpenReader: could not update screen wake lock: $error');
        }),
      );
    }
    _restorePage();
    _paintWord();
  }

  void _restorePage() {
    if (_positionRestored || !_viewer.isReady || !_playback.connected) return;
    _positionRestored = true;
    final target = _playback.plan
        .where(
          (segment) => integer(segment['ordinal']) == _playback.currentOrdinal,
        )
        .firstOrNull;
    unawaited(_goTo(integer(object(target?['locator'])['page'], 1)));
  }

  void _paintWord() {
    final word = _playback.activeWord;
    if (!_viewer.isReady || !_playback.connected) return;
    final ordinal = word?.ordinal ?? _playback.currentOrdinal;
    final segment = _playback.plan
        .where((segment) => integer(segment['ordinal']) == ordinal)
        .firstOrNull;
    final pageNumber =
        word?.page ?? integer(object(segment?['locator'])['page'], 1);
    final signature = '$ordinal:${word?.wordIndex ?? -1}:$pageNumber';
    if (signature == _wordSignature) return;
    _wordSignature = signature;
    if (_follow && _playback.wantedPlaying && pageNumber != _page) {
      unawaited(_goTo(pageNumber));
    }
    unawaited(_loadText(pageNumber));
    final native = _texts[pageNumber];
    final segmentText = segment?['text'] as String? ?? '';
    final rects = <PdfRect>[];
    final pages = objects(
      object(_playback.payload?['parsedDocument'])['pages'],
    );
    final blockId = object(segment?['locator'])['blockId'];
    final block = pages
        .expand((page) => objects(page['blocks']))
        .where((row) => row['id'] == blockId)
        .firstOrNull;
    final fragments = objects(block?['fragments'])
        .where((row) => integer(row['page']) == pageNumber);
    final bounds = <Rect>[];
    for (final fragment in fragments) {
      final box = fragment['bbox'];
      if (box is List && box.length == 4 && box.every((n) => n is num)) {
        bounds.add(
          Rect.fromLTRB(
            (box[0] as num).toDouble(),
            (box[1] as num).toDouble(),
            (box[2] as num).toDouble(),
            (box[3] as num).toDouble(),
          ),
        );
      }
    }
    if (native != null && word != null) {
      final glyphs = pdfWordGlyphs(
        pageText: native.fullText,
        characterRects: native.charRects
            .map((rect) => rect.toRect(page: _viewer.pages[pageNumber - 1]))
            .toList(),
        blockBounds: bounds,
        segmentText: segmentText,
        word: word,
      );
      for (final index in glyphs) {
        final rect = native.charRects[index];
        if (rect.width > 0 && rect.height > 0) rects.add(rect);
      }
    }
    final matchedWord = rects.isNotEmpty && word != null;
    // Image-only pages have no native glyph geometry; show the parsed block
    // and keep exact word tracking in the native transcript.
    if (rects.isEmpty) {
      if (pageNumber >= 1 && pageNumber <= _viewer.pageCount) {
        final height = _viewer.pages[pageNumber - 1].height;
        for (final fragment in objects(block?['fragments'])) {
          if (integer(fragment['page']) != pageNumber) continue;
          final box = fragment['bbox'];
          if (box is List && box.length == 4 && box.every((n) => n is num)) {
            rects.add(
              PdfRect(
                (box[0] as num).toDouble(),
                height - (box[1] as num).toDouble(),
                (box[2] as num).toDouble(),
                height - (box[3] as num).toDouble(),
              ),
            );
          }
        }
      }
    }
    _highlight.value = _PageHighlight(
      pageNumber,
      rects,
      matchedWord ? word.text : null,
    );
  }

  Future<void> _goTo(int page) async {
    if (!_viewer.isReady || page < 1 || page > _viewer.pageCount) return;
    await _viewer.goToPage(pageNumber: page);
    if (mounted) await _loadText(page);
  }

  Future<void> _choosePage() async {
    final input = TextEditingController(text: '$_page');
    final number = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Page (1-$_pageCount)'),
          onSubmitted: (value) => Navigator.pop(context, int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(input.text)),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    // Dialog exit animations can still hold its editable widget.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (mounted && number != null) await _goTo(number);
  }

  Future<void> _readPage() async {
    final segment = _playback.plan
        .where(
          (segment) => integer(object(segment['locator'])['page'], 1) >= _page,
        )
        .firstOrNull;
    if (segment != null) {
      await _playback.startAt(integer(segment['ordinal']));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No readable text on this page.')),
      );
    }
  }

  Future<void> _togglePdfDark() async {
    setState(() {
      _pdfDark = !_pdfDark;
      if (_pdfBytes != null) _pdfWidget = _createPdf(_pdfBytes!);
    });
    final saved = await widget.preferences.setBool('pdfDarkMode', _pdfDark);
    if (!saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save your PDF appearance.')),
      );
    }
  }

  Future<void> _saveOffline({bool prepareAudio = false}) async {
    if (_savingOffline || _pdfBytes == null || _playback.payload == null) {
      return;
    }
    setState(() => _savingOffline = true);
    try {
      final store = await OfflineStore.open();
      final saved = await store.save(
        origin: _playback.api.base.origin,
        account: widget.preferences.getString('email') ?? 'owner',
        document: _serverDocument ?? widget.document,
        payload: {
          ..._playback.payload!,
          'initialPosition': {
            ...object(_playback.payload!['initialPosition']),
            'segmentOrdinal': _playback.currentOrdinal,
          },
        },
        bytes: _pdfBytes!,
      );
      _savedDocument = saved;
      if (!mounted) return;
      if (prepareAudio) {
        await _playback.pause();
        if (!mounted) return;
        await showPrepareAudio(
          context,
          saved,
          widget.preferences.getString('offlineVoice') ?? 'am_michael',
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'PDF saved on this phone. Install voices in Offline library to read without your server.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save this PDF offline: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingOffline = false);
    }
  }

  Future<void> _switchSource(bool phone) async {
    if (_switchingSource || phone == _playback.isOffline) return;
    setState(() => _switchingSource = true);
    final previous = _playback;
    final wasPlaying = previous.wantedPlaying;
    final passage =
        previous.plan
            .where((row) => row['ordinal'] == previous.currentOrdinal)
            .firstOrNull ??
        <String, dynamic>{};
    final word = previous.activeWord;
    final page = integer(object(passage['locator'])['page'], _page);
    ReaderPlayback? target;
    try {
      await previous.pause();
      OpenReaderApi api;
      OfflineDocument? saved;
      Json document = _serverDocument ?? widget.document;
      if (phone) {
        if (_savedDocument == null) await _saveOffline();
        saved = _savedDocument;
        if (saved == null) {
          throw const ReaderException(
            'Save the PDF offline before using the phone voice.',
          );
        }
        api = OpenReaderApi(Uri.parse(saved.origin));
        _ownedApis.add(api);
        document = saved.document;
      } else {
        final server = widget.preferences.getString('server');
        if (server == null || server.isEmpty) {
          throw const ReaderException(
            'Sign into your OpenReader server from the connection screen first.',
          );
        }
        api = OpenReaderApi(OpenReaderApi.parseServer(server));
        _ownedApis.add(api);
        if (!await api.restore()) {
          throw const ReaderException(
            'Sign into your OpenReader server first, then reopen this PDF.',
          );
        }
        if (_savedDocument?.importedOnPhone == true &&
            _serverDocument == null) {
          if (!mounted) return;
          final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Read this phone PDF on your server?'),
              content: const Text(
                'A copy must be uploaded to your configured OpenReader server for server narration. Your phone copy stays saved.',
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
          document = await api.uploadPdf(
            _pdfBytes!,
            '${widget.document['name']}',
          );
          _serverDocument = document;
        }
      }
      target = ReaderPlayback(
        api,
        document['id'] as String,
        widget.preferences,
        offline: saved,
      );
      await target.prepare();
      if (target.error != null) throw ReaderException(target.error!);
      if (!mounted) {
        await target.close();
        return;
      }
      final ordinal =
          matchingPassage(target.plan, passage, page, word) ??
          integer(
            target.plan
                .where((row) => integer(object(row['locator'])['page']) >= page)
                .firstOrNull?['ordinal'],
          );
      await target.selectAt(ordinal);
      previous.removeListener(_onPlayback);
      setState(() {
        _playback = target!;
        _wordSignature = '';
      });
      _playback.addListener(_onPlayback);
      _onPlayback();
      unawaited(
        previous.close().catchError((Object error) {
          debugPrint('OpenReader: previous voice cleanup: $error');
        }),
      );
      if (wasPlaying) await _playback.startAt(ordinal);
    } catch (error) {
      if (target != null && !identical(target, _playback)) await target.close();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not switch voice source: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _switchingSource = false);
    }
  }

  Widget _sourceButton() => PopupMenuButton<bool>(
    key: const Key('voice-source'),
    tooltip: 'Choose phone or server voice',
    enabled: !_switchingSource,
    onSelected: _switchSource,
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: true,
        checked: _playback.isOffline,
        child: const Text('Phone / offline'),
      ),
      CheckedPopupMenuItem(
        value: false,
        checked: !_playback.isOffline,
        child: const Text('Server'),
      ),
    ],
    icon: Icon(
      _playback.isOffline ? Icons.phone_android : Icons.cloud_outlined,
    ),
  );
  Future<void> _setFullscreen(bool enabled) async {
    if (_changingFullscreen || enabled == _fullscreen) return;
    setState(() {
      _fullscreen = enabled;
      _changingFullscreen = true;
    });
    try {
      await _window.invokeMethod<void>('setFullscreen', {'enabled': enabled});
    } on PlatformException {
      if (mounted) {
        setState(() => _fullscreen = !enabled);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not change fullscreen mode.')),
        );
      }
    } finally {
      if (mounted) setState(() => _changingFullscreen = false);
    }
  }

  Widget _darkPageButton() => IconButton(
    key: const Key('toggle-pdf-dark'),
    tooltip: _pdfDark
        ? 'Use light PDF pages'
        : 'Dark PDF pages (inverts images)',
    onPressed: _togglePdfDark,
    isSelected: _pdfDark,
    icon: Icon(_pdfDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
  );

  Widget _fullscreenButtons() => Positioned(
    top: 0,
    right: 0,
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(28),
          elevation: 3,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _darkPageButton(),
              _sourceButton(),
              AnimatedBuilder(
                animation: _playback,
                builder: (context, _) => IconButton(
                  key: const Key('fullscreen-play-pause'),
                  tooltip: _playback.wantedPlaying ? 'Pause' : 'Listen',
                  onPressed:
                      _playback.connected &&
                          !_playback.preparing &&
                          !_switchingSource
                      ? _playback.toggle
                      : null,
                  icon: _playback.preparing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _playback.wantedPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
              ),
              IconButton(
                key: const Key('exit-fullscreen'),
                tooltip: 'Exit fullscreen',
                onPressed: _changingFullscreen
                    ? null
                    : () => _setFullscreen(false),
                icon: const Icon(Icons.fullscreen_exit),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    if (_fullscreen) {
      unawaited(
        _window
            .invokeMethod<void>('setFullscreen', {'enabled': false})
            .catchError((Object error) {
              debugPrint('OpenReader: unable to restore system bars: $error');
            }),
      );
    }
    _playback.removeListener(_onPlayback);
    unawaited(
      _playback.close().whenComplete(() {
        for (final api in _ownedApis) {
          api.close();
        }
      }),
    );
    _highlight.dispose();
    unawaited(
      WakelockPlus.disable().catchError((Object error) {
        debugPrint('OpenReader: could not release screen wake lock: $error');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_fullscreen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _fullscreen) unawaited(_setFullscreen(false));
    },
    child: Scaffold(
      appBar: _fullscreen
          ? null
          : AppBar(
              title: Text(
                '${widget.document['name']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                _darkPageButton(),
                IconButton(
                  key: const Key('toggle-transcript'),
                  tooltip: _transcriptVisible
                      ? 'Hide Now Reading'
                      : 'Show Now Reading',
                  onPressed: () =>
                      setState(() => _transcript = !_transcriptVisible),
                  isSelected: _transcriptVisible,
                  icon: const Icon(Icons.notes_rounded),
                ),
                IconButton(
                  key: const Key('enter-fullscreen'),
                  tooltip: 'Fullscreen PDF',
                  onPressed: _changingFullscreen
                      ? null
                      : () => _setFullscreen(true),
                  icon: const Icon(Icons.fullscreen),
                ),
                if (!_playback.isOffline)
                  PopupMenuButton<String>(
                    key: const Key('reader-menu'),
                    tooltip: 'PDF options',
                    onSelected: (value) =>
                        _saveOffline(prepareAudio: value == 'all-audio'),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        key: const Key('save-offline'),
                        value: 'offline',
                        enabled:
                            !_savingOffline &&
                            _pdfBytes != null &&
                            _playback.connected,
                        child: Text(
                          _savingOffline
                              ? 'Saving offline...'
                              : 'Save PDF for offline reading',
                        ),
                      ),
                      PopupMenuItem(
                        value: 'all-audio',
                        enabled:
                            !_savingOffline &&
                            _pdfBytes != null &&
                            _playback.connected,
                        child: const Text('Save PDF + prepare all phone audio'),
                      ),
                    ],
                  ),
              ],
            ),
      body: Stack(
        children: [
          SafeArea(
            top: false,
            bottom: !_fullscreen,
            left: !_fullscreen,
            right: !_fullscreen,
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 700;
                      final pdf = _pdfError != null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _pdfError!,
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 12),
                                    FilledButton(
                                      onPressed: _downloadPdf,
                                      child: const Text('Retry PDF'),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : _pdfWidget ??
                                const Center(
                                  child: CircularProgressIndicator(),
                                );
                      // Keep the PDF at the same element-tree location when folding.
                      return Flex(
                        direction: wide ? Axis.horizontal : Axis.vertical,
                        children: [
                          Expanded(
                            child: RepaintBoundary(
                              key: const Key('pdf-surface'),
                              child: pdf,
                            ),
                          ),
                          if (_transcriptVisible)
                            SizedBox(
                              width: wide ? 280 : null,
                              height: wide ? null : 160,
                              child: _transcriptPanel(),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                if (!_fullscreen)
                  Row(
                    key: const Key('page-controls'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Previous page',
                        onPressed: _page > 1 ? () => _goTo(_page - 1) : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _pageCount > 0 ? _choosePage : null,
                        child: Text('Page $_page / $_pageCount'),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Next page',
                        onPressed: _page < _pageCount
                            ? () => _goTo(_page + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: _follow
                            ? 'Turn off follow narration'
                            : 'Follow narration',
                        isSelected: _follow,
                        onPressed: () => setState(() => _follow = !_follow),
                        icon: const Icon(Icons.my_location),
                      ),
                      IconButton(
                        key: const Key('fit-page'),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Fit page',
                        onPressed: _viewer.isReady
                            ? () => _viewer.goToArea(
                                rect: _viewer.layout.pageLayouts[_page - 1],
                                duration: const Duration(milliseconds: 150),
                              )
                            : null,
                        icon: const Icon(Icons.fit_screen),
                      ),
                    ],
                  ),
                if (!_fullscreen) _controls(),
              ],
            ),
          ),
          if (_fullscreen) _fullscreenButtons(),
        ],
      ),
    ),
  );

  Widget _transcriptPanel() => AnimatedBuilder(
    animation: _playback,
    builder: (context, _) {
      final segment = _playback.plan
          .where(
            (segment) =>
                integer(segment['ordinal']) == _playback.currentOrdinal,
          )
          .firstOrNull;
      final text = segment?['text'] as String? ?? '';
      final word = _playback.activeWord;
      final start = word?.start ?? -1;
      final end = word?.end ?? -1;
      return SingleChildScrollView(
        key: const Key('now-reading-panel'),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NOW READING', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 14),
            Text.rich(
              key: const Key('transcript'),
              TextSpan(
                children: start >= 0 && end > start && end <= text.length
                    ? [
                        TextSpan(text: text.substring(0, start)),
                        TextSpan(
                          text: text.substring(start, end),
                          style: const TextStyle(
                            backgroundColor: Color(0xffffd65c),
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(text: text.substring(end)),
                      ]
                    : [TextSpan(text: text.isEmpty ? _playback.status : text)],
              ),
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(height: 1.65),
            ),
            const SizedBox(height: 20),
            Text(
              _playback.isOffline
                  ? 'Kokoro runs entirely on this phone. Offline word timing is approximate.'
                  : 'PDF text is highlighted when glyphs are available. '
                        'Image-only or rewritten text uses block highlighting; '
                        'the transcript follows the spoken word.',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    },
  );

  Widget _controls() => AnimatedBuilder(
    animation: _playback,
    builder: (context, _) => Material(
      key: const Key('playback-bar'),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_playback.preparing) const LinearProgressIndicator(),
            const SizedBox(height: 2),
            Text(
              _switchingSource
                  ? 'Switching voice source...'
                  : _playback.wantedPlaying &&
                        !_playback.preparing &&
                        _playback.activeWord == null
                  ? '${_playback.status} / passage highlighting'
                  : _playback.status,
              key: const Key('playback-status'),
              textAlign: TextAlign.center,
              maxLines: _playback.error != null ? 3 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: _playback.error != null
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Previous passage',
                  onPressed:
                      !_playback.connected ||
                          _playback.preparing ||
                          _switchingSource
                      ? null
                      : () {
                          final previous = _playback.plan
                              .where(
                                (segment) =>
                                    integer(segment['ordinal']) <
                                    _playback.currentOrdinal,
                              )
                              .lastOrNull;
                          if (previous != null) {
                            unawaited(
                              _playback.startAt(integer(previous['ordinal'])),
                            );
                          }
                        },
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                FilledButton(
                  key: const Key('play-pause'),
                  onPressed:
                      !_playback.connected ||
                          _playback.preparing ||
                          _switchingSource
                      ? null
                      : _playback.toggle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _playback.wantedPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _playback.error != null
                              ? 'Retry audio'
                              : _playback.wantedPlaying
                              ? 'Pause'
                              : 'Listen',
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next passage',
                  onPressed:
                      !_playback.connected ||
                          _playback.preparing ||
                          _switchingSource
                      ? null
                      : () {
                          final next = _playback.plan
                              .where(
                                (segment) =>
                                    integer(segment['ordinal']) >
                                    _playback.currentOrdinal,
                              )
                              .firstOrNull;
                          if (next != null) {
                            unawaited(
                              _playback.startAt(integer(next['ordinal'])),
                            );
                          }
                        },
                  icon: const Icon(Icons.skip_next_rounded),
                ),
                PopupMenuButton<double>(
                  tooltip: _playback.isOffline
                      ? 'Phone speed (saved separately)'
                      : 'Server speed (saved separately)',
                  initialValue: _playback.speed,
                  onSelected: _playback.setSpeed,
                  itemBuilder: (_) => [
                    for (final speed in [.75, .9, 1.0, 1.1, 1.25, 1.5, 2.0])
                      PopupMenuItem(value: speed, child: Text('${speed}x')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('${_playback.speed}x'),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                _sourceButton(),
                Expanded(
                  child: _playback.isOffline
                      ? PopupMenuButton<String>(
                          tooltip: 'Choose offline voice',
                          initialValue: _playback.offlineVoice,
                          onSelected: _playback.setOfflineVoice,
                          itemBuilder: (_) => [
                            for (final voice in offlineVoices.entries)
                              PopupMenuItem(
                                value: voice.key,
                                child: Text(voice.value),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _playback.voice,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.arrow_drop_down, size: 18),
                              ],
                            ),
                          ),
                        )
                      : Text(
                          _playback.voice,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _playback.connected && !_playback.preparing
                      ? _readPage
                      : null,
                  child: const Text('Read this page'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _WordPainter extends CustomPainter {
  _WordPainter(this.page, this.highlight) : super(repaint: highlight);
  final PdfPage page;
  final ValueNotifier<_PageHighlight?> highlight;
  @override
  void paint(Canvas canvas, Size size) {
    final value = highlight.value;
    if (value == null || value.page != page.pageNumber) return;
    final paint = Paint()
      ..color = const Color(0xffffcc32).withValues(alpha: .48);
    for (final rect in value.rects) {
      canvas.drawRect(
        Rect.fromLTRB(
          rect.left / page.width * size.width,
          (page.height - rect.top) / page.height * size.height,
          rect.right / page.width * size.width,
          (page.height - rect.bottom) / page.height * size.height,
        ).inflate(1),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WordPainter oldDelegate) =>
      oldDelegate.page != page || oldDelegate.highlight != highlight;
}
