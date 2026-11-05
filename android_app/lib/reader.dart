import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
import 'server_narration.dart';

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

class _SearchMatch {
  const _SearchMatch({
    required this.ordinal,
    required this.page,
    required this.text,
    required this.matchStart,
    required this.matchEnd,
  });
  final int ordinal;
  final int page;
  final String text;
  final int matchStart;
  final int matchEnd;
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
  bool _viewerLaidOut = false;
  bool _fullscreen = false;
  bool _pdfDark = false;
  String _colorTheme = 'light'; // 'light', 'sepia', 'dark', 'contrast'
  bool _reflowMode = false;
  double _reflowFontSize = 18.0;
  bool _searching = false;
  final TextEditingController _searchController = TextEditingController();
  List<_SearchMatch> _searchMatches = [];
  int _searchIndex = 0;
  Set<int> _bookmarks = {};
  double? _scrubPassage;
  bool _changingFullscreen = false;
  bool _savingOffline = false;

  // Adobe-style right-edge fast scroll pill state:
  // Only appears when scrolling the document or grabbing the pill.
  bool _scrollPillVisible = false;
  bool _draggingScrollPill = false;
  int? _dragTargetPage;
  double? _lastVisibleTop;
  Timer? _scrollPillHideTimer;

  static const _adobeBarBg = Color(0xff1c1c1e);
  static const _adobeSheetBg = Color(0xff202024);
  static const _adobeButtonBg = Color(0xff2c2c30);

  static const _window = MethodChannel('com.homelab.openreader_native/reader');
  static const _darkPageColors = ColorFilter.matrix([
    -0.88, 0, 0, 0, 247,
    0, -0.88, 0, 0, 249,
    0, 0, -0.88, 0, 253,
    0, 0, 0, 1, 0,
  ]);
  static const _sepiaPageColors = ColorFilter.matrix([
    0.94, 0.04, 0.0, 0, 8,
    0.02, 0.89, 0.02, 0, 4,
    0.0, 0.04, 0.76, 0, -8,
    0, 0, 0, 1, 0,
  ]);
  static const _contrastPageColors = ColorFilter.matrix([
    -1.15, 0, 0, 0, 255,
    0, -1.15, 0, 0, 255,
    0, 0, -1.15, 0, 255,
    0, 0, 0, 1, 0,
  ]);

  String _wordSignature = '';
  bool get _transcriptVisible =>
      !_fullscreen &&
      !_reflowMode &&
      (_transcript ?? (MediaQuery.sizeOf(context).width >= 700));

  String get _bookmarksKey => 'bookmarks:${widget.document['id']}';

  int get _effectiveMaxPages => math.max(
    1,
    _pageCount > 0
        ? _pageCount
        : _playback.plan.fold<int>(
            1,
            (m, s) => math.max(m, integer(object(s['locator'])['page'], 1)),
          ),
  );

  @override
  void initState() {
    super.initState();
    _pdfDark = widget.preferences.getBool('pdfDarkMode') ?? false;
    _colorTheme =
        widget.preferences.getString('pdfColorTheme') ??
        (_pdfDark ? 'dark' : 'light');
    _reflowFontSize = widget.preferences.getDouble('reflowFontSize') ?? 18.0;
    _loadBookmarks();
    _savedDocument = widget.offline;
    _viewer.addListener(_onViewerScrolled);
    _playback = ReaderPlayback(
      widget.api,
      widget.document['id'] as String,
      widget.preferences,
      offline: widget.offline,
    )..addListener(_onPlayback);
    unawaited(_open());
  }

  void _onViewerScrolled() {
    if (!mounted || !_viewer.isReady) return;
    final top = _viewer.visibleRect.top;
    if (_lastVisibleTop == null) {
      _lastVisibleTop = top;
      return;
    }
    if ((top - _lastVisibleTop!).abs() > 1.5) {
      _lastVisibleTop = top;
      _revealScrollPill();
    }
  }

  void _revealScrollPill() {
    if (!mounted) return;
    if (!_scrollPillVisible) {
      setState(() => _scrollPillVisible = true);
    }
    _scheduleHideScrollPill();
  }

  void _scheduleHideScrollPill() {
    _scrollPillHideTimer?.cancel();
    _scrollPillHideTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_draggingScrollPill && _scrollPillVisible) {
        setState(() => _scrollPillVisible = false);
      }
    });
  }

  void _loadBookmarks() {
    try {
      final raw = widget.preferences.getString(_bookmarksKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _bookmarks = decoded
              .map((e) => integer(e))
              .where((p) => p > 0)
              .toSet();
        }
      }
    } catch (_) {}
  }

  Future<void> _toggleBookmark([int? targetPage]) async {
    final p = targetPage ?? _page;
    if (p < 1) return;
    setState(() {
      if (_bookmarks.contains(p)) {
        _bookmarks.remove(p);
      } else {
        _bookmarks.add(p);
      }
    });
    final sorted = _bookmarks.toList()..sort();
    await widget.preferences.setString(_bookmarksKey, jsonEncode(sorted));
  }

  Future<void> _open() async {
    unawaited(_playback.prepare().then((_) => _autoSyncReadyServerAudio()));
    await _downloadPdf();
  }

  Future<void> _activateSavedAudioIfReady(OfflineDocument doc) async {
    if (!mounted) return;
    final src = widget.preferences.getString('offline-source:${doc.key}');
    if (src == 'server' && await ServerNarration(doc).load() != null) {
      await _switchSource('saved-server');
    } else if (src == 'phone') {
      await _switchSource('phone');
    }
  }

  Future<void> _autoSyncReadyServerAudio() async {
    if (!mounted || _playback.usesSavedServer) return;
    try {
      final store = await OfflineStore.open();
      final docId = '${widget.document['id']}';
      if (_savedDocument == null) {
        final docs = await store.documents();
        for (final d in docs) {
          if ('${d.document['id']}' == docId) {
            _savedDocument = d;
            break;
          }
        }
      }
      if (_savedDocument != null &&
          await ServerNarration(_savedDocument!).load() != null) {
        await widget.preferences.setString(
          'offline-source:${_savedDocument!.key}',
          'server',
        );
        if (mounted) await _switchSource('saved-server');
        return;
      }
      final payload = _playback.payload;
      if (payload == null) return;
      final plan = object(payload['plan']);
      final request = object(object(payload['playback'])['request']);
      if (plan['planObjectKey'] is! String || request.isEmpty) return;
      final snapshot = await _playback.api.post('/api/tts/export/resolve', {
        ...request,
        'planId': plan['planId'],
        'planObjectKey': plan['planObjectKey'],
        'planSignature': plan['planSignature'],
        'startIntent': {'selectedOrdinal': 0},
        'format': 'mp3',
        'speed': 1,
        'includeProgress': true,
        'action': 'resolve',
      });
      final genState = object(snapshot['generation'])['state'];
      final artState = object(snapshot['artifact'])['state'];
      if (genState == 'complete' &&
          (artState == 'ready' || artState == 'none' || artState == 'stale')) {
        while (_pdfBytes == null && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        if (!mounted || _pdfBytes == null) return;
        _savedDocument ??= await store.save(
          origin: _playback.api.base.origin,
          account: widget.preferences.getString('email') ?? 'owner',
          document: _serverDocument ?? widget.document,
          payload: payload,
          bytes: _pdfBytes!,
        );
        final ok = await ServerNarration(_savedDocument!).prepare(
          _playback.api,
          payload,
          canceled: () => !mounted,
          onProgress: (msg, _) {
            if (mounted) {
              setState(() => _playback.status = msg);
            }
          },
        );
        if (ok && mounted) {
          await widget.preferences.setString(
            'offline-source:${_savedDocument!.key}',
            'server',
          );
          await widget.preferences.remove(
            ServerNarration.pendingKey(_savedDocument!),
          );
          await _switchSource('saved-server');
        }
      }
    } catch (_) {}
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

  ColorFilter? get _activeColorFilter {
    switch (_colorTheme) {
      case 'dark':
        return _darkPageColors;
      case 'sepia':
        return _sepiaPageColors;
      case 'contrast':
        return _contrastPageColors;
      default:
        return null;
    }
  }

  Color get _activeBackgroundColor {
    switch (_colorTheme) {
      case 'dark':
        return const Color(0xff141416);
      case 'contrast':
        return Colors.black;
      case 'sepia':
        return const Color(0xffdfd3b8);
      default:
        return const Color(0xff2b2b2e);
    }
  }

  Widget _createPdf(Uint8List bytes) => PdfViewer.data(
    bytes,
    sourceName: widget.document['id'] as String,
    controller: _viewer,
    params: PdfViewerParams(
      margin: 4,
      panAxis: PanAxis.free,
      boundaryMargin: EdgeInsets.zero,
      sizeDelegateProvider: const PdfViewerSizeDelegateProviderSmart(),
      backgroundColor: _activeBackgroundColor,
      pageImageColorFilter: _activeColorFilter,
      pageDropShadow: const BoxShadow(
        color: Colors.black38,
        blurRadius: 3,
        offset: Offset(0, 1),
      ),
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
        _viewerLaidOut = true;
        setState(() => _pageCount = document.pages.length);
        _restorePage();
      },
      onPageChanged: (page) {
        if (!mounted || page == null) return;
        final changed = page != _page;
        setState(() => _page = page);
        if (changed && _positionRestored) {
          _revealScrollPill();
        }
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
    if (_positionRestored ||
        !_viewerLaidOut ||
        !_viewer.isReady ||
        !_playback.connected) {
      return;
    }
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
    if (!_playback.connected) return;
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
      if (_reflowMode) {
        setState(() => _page = pageNumber);
      } else {
        unawaited(_goTo(pageNumber));
      }
    }
    if (!_viewer.isReady) return;
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

  Future<void> _goTo(
    int page, {
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    final maxPage = _effectiveMaxPages;
    if (page < 1 || page > maxPage) return;
    setState(() => _page = page);
    if (_viewerLaidOut && _viewer.isReady && page <= _viewer.pageCount) {
      await _viewer.goToPage(pageNumber: page, duration: duration);
      if (mounted) await _loadText(page);
    }
  }

  Future<void> _choosePage() async {
    final maxPages = _effectiveMaxPages;
    final input = TextEditingController(text: '$_page');
    final number = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _adobeSheetBg,
        title: const Text(
          'Go to page',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Page (1-$maxPages)',
            labelStyle: const TextStyle(color: Colors.white70),
          ),
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
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (mounted && number != null) await _goTo(number);
  }

  Future<void> _readPage([int? targetPage]) async {
    final p = targetPage ?? _page;
    final segment = _playback.plan
        .where(
          (segment) => integer(object(segment['locator'])['page'], 1) >= p,
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

  Future<void> _setColorTheme(String theme) async {
    setState(() {
      _colorTheme = theme;
      _pdfDark = theme == 'dark' || theme == 'contrast';
      if (_pdfBytes != null) _pdfWidget = _createPdf(_pdfBytes!);
    });
    await widget.preferences.setBool('pdfDarkMode', _pdfDark);
    await widget.preferences.setString('pdfColorTheme', theme);
  }

  Future<void> _togglePdfDark() async {
    await _setColorTheme(_pdfDark ? 'light' : 'dark');
  }

  void _runSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() {
        _searchMatches = [];
        _searchIndex = 0;
      });
      return;
    }
    final matches = <_SearchMatch>[];
    for (final segment in _playback.plan) {
      final text = '${segment['text'] ?? ''}';
      final lower = text.toLowerCase();
      final idx = lower.indexOf(q);
      if (idx != -1) {
        matches.add(
          _SearchMatch(
            ordinal: integer(segment['ordinal']),
            page: integer(object(segment['locator'])['page'], 1),
            text: text,
            matchStart: idx,
            matchEnd: idx + q.length,
          ),
        );
      }
    }
    setState(() {
      _searchMatches = matches;
      _searchIndex = 0;
    });
    if (matches.isNotEmpty) {
      unawaited(_jumpToSearchMatch(0));
    }
  }

  Future<void> _jumpToSearchMatch(int index) async {
    if (_searchMatches.isEmpty) return;
    final clamped =
        (index % _searchMatches.length + _searchMatches.length) %
        _searchMatches.length;
    final match = _searchMatches[clamped];
    setState(() => _searchIndex = clamped);
    await _goTo(match.page);
    if (_playback.connected) {
      await _playback.selectAt(match.ordinal);
    }
  }

  List<({String title, int page, int ordinal})> _extractOutline() {
    final items = <({String title, int page, int ordinal})>[];
    final seenPages = <int>{};
    for (final seg in _playback.plan) {
      final text = '${seg['text'] ?? ''}'.trim();
      final page = integer(object(seg['locator'])['page'], 1);
      final ordinal = integer(seg['ordinal']);
      if (text.isEmpty) continue;
      final isHeading =
          (text.length <= 90 &&
              !text.endsWith('.') &&
              (RegExp(
                    r'^(Chapter|Section|Part|Module|Phase|Topic|\d+[\.\)]\s|[A-Z][A-Z0-9\s\-:]{4,})',
                  ).hasMatch(text) ||
                  !seenPages.contains(page)));
      if (isHeading && items.length < 150) {
        seenPages.add(page);
        items.add((
          title: text.replaceAll(RegExp(r'\s+'), ' '),
          page: page,
          ordinal: ordinal,
        ));
      }
    }
    return items;
  }

  Future<void> _showNavigationSheet({int initialTab = 0}) async {
    final outline = _extractOutline();
    final totalPages = _effectiveMaxPages;
    final byPage = <int, List<Json>>{};
    for (final s in _playback.plan) {
      final p = integer(object(s['locator'])['page'], 1);
      (byPage[p] ??= []).add(s);
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _adobeSheetBg,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => Theme(
        data: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: _adobeSheetBg,
          colorScheme: const ColorScheme.dark(
            surface: _adobeSheetBg,
            primary: Color(0xff4da3ff),
          ),
        ),
        child: DefaultTabController(
          initialIndex: initialTab,
          length: 3,
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.74,
            minChildSize: 0.45,
            maxChildSize: 0.94,
            builder: (context, scrollController) => Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 6),
                const TabBar(
                  tabs: [
                    Tab(
                      icon: Icon(Icons.toc_rounded),
                      text: 'Table of Contents',
                    ),
                    Tab(icon: Icon(Icons.grid_view_rounded), text: 'Pages'),
                    Tab(
                      icon: Icon(Icons.bookmarks_outlined),
                      text: 'Bookmarks',
                    ),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      // Tab 1: Table of Contents / Sections
                      outline.isEmpty
                          ? const Center(
                              child: Text('No sections detected in this PDF.'),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              itemCount: outline.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1, color: Colors.white12),
                              itemBuilder: (context, index) {
                                final item = outline[index];
                                final active = item.page == _page;
                                return ListTile(
                                  selected: active,
                                  leading: CircleAvatar(
                                    radius: 16,
                                    backgroundColor: active
                                        ? const Color(0xff4da3ff)
                                        : _adobeButtonBg,
                                    child: Text(
                                      '${item.page}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text('Page ${item.page}'),
                                  trailing: IconButton(
                                    tooltip: 'Read from here',
                                    icon: const Icon(
                                      Icons.play_circle_fill_rounded,
                                    ),
                                    onPressed: () {
                                      Navigator.pop(sheetContext);
                                      unawaited(_goTo(item.page));
                                      unawaited(_playback.startAt(item.ordinal));
                                    },
                                  ),
                                  onTap: () {
                                    Navigator.pop(sheetContext);
                                    unawaited(_goTo(item.page));
                                    if (_playback.connected) {
                                      unawaited(
                                        _playback.selectAt(item.ordinal),
                                      );
                                    }
                                  },
                                );
                              },
                            ),
                      // Tab 2: Visual Page Grid (1..N)
                      GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 150,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 0.78,
                            ),
                        itemCount: totalPages,
                        itemBuilder: (context, index) {
                          final p = index + 1;
                          final segs = byPage[p] ?? const [];
                          final preview = segs.isNotEmpty
                              ? '${segs.first['text'] ?? ''}'
                              : 'Page $p';
                          final isCurrent = p == _page;
                          final isBookmarked = _bookmarks.contains(p);
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              unawaited(_goTo(p));
                            },
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? const Color(0xff263b54)
                                    : _adobeButtonBg,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isCurrent
                                      ? const Color(0xff4da3ff)
                                      : Colors.white12,
                                  width: isCurrent ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'P. $p',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                      if (isBookmarked)
                                        const Icon(
                                          Icons.star_rounded,
                                          size: 16,
                                          color: Color(0xff4da3ff),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Expanded(
                                    child: Text(
                                      preview,
                                      maxLines: 5,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '${segs.length} passages',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.white54,
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () {
                                          Navigator.pop(sheetContext);
                                          unawaited(_goTo(p));
                                          unawaited(_readPage(p));
                                        },
                                        child: const Icon(
                                          Icons.headphones_rounded,
                                          size: 16,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      // Tab 3: Bookmarks
                      StatefulBuilder(
                        builder: (context, setModalState) {
                          final sorted = _bookmarks.toList()..sort();
                          if (sorted.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('No bookmarked pages yet.'),
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                    onPressed: () async {
                                      await _toggleBookmark(_page);
                                      setModalState(() {});
                                    },
                                    icon: const Icon(
                                      Icons.bookmark_add_outlined,
                                    ),
                                    label: Text('Bookmark Page $_page'),
                                  ),
                                ],
                              ),
                            );
                          }
                          return ListView.separated(
                            itemCount: sorted.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, color: Colors.white12),
                            itemBuilder: (context, index) {
                              final p = sorted[index];
                              final segs = byPage[p] ?? const [];
                              final preview = segs.isNotEmpty
                                  ? '${segs.first['text'] ?? ''}'
                                  : 'Page $p';
                              return ListTile(
                                leading: const Icon(
                                  Icons.bookmark_rounded,
                                  color: Color(0xff4da3ff),
                                ),
                                title: Text('Page $p'),
                                subtitle: Text(
                                  preview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Read page $p',
                                      icon: const Icon(
                                        Icons.headphones_rounded,
                                      ),
                                      onPressed: () {
                                        Navigator.pop(sheetContext);
                                        unawaited(_goTo(p));
                                        unawaited(_readPage(p));
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Remove bookmark',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () async {
                                        await _toggleBookmark(p);
                                        setModalState(() {});
                                      },
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  unawaited(_goTo(p));
                                },
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showViewSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _adobeSheetBg,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'View settings',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'COLOR THEME',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in const [
                    ('light', 'Light', Icons.light_mode_outlined),
                    ('dark', 'Night Dark', Icons.dark_mode_outlined),
                    ('sepia', 'Warm Sepia', Icons.wb_sunny_outlined),
                    ('contrast', 'High Contrast', Icons.contrast_rounded),
                  ])
                    ChoiceChip(
                      selected: _colorTheme == entry.$1,
                      label: Text(entry.$2),
                      avatar: Icon(entry.$3, size: 16),
                      onSelected: (_) async {
                        await _setColorTheme(entry.$1);
                        setModalState(() {});
                      },
                    ),
                ],
              ),
              const Divider(height: 24, color: Colors.white12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(
                  Icons.water_drop_outlined,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Liquid Reading Mode (Reflow)',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Large resizable text cards with live word highlighting',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                value: _reflowMode,
                onChanged: (val) {
                  setState(() => _reflowMode = val);
                  setModalState(() {});
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(
                  Icons.my_location_rounded,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Follow narration automatically',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Auto-scroll pages as read-aloud advances',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                value: _follow,
                onChanged: (val) {
                  setState(() => _follow = val);
                  setModalState(() {});
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(
                  Icons.subtitles_outlined,
                  color: Colors.white70,
                ),
                title: const Text(
                  'Show Now Reading transcript panel',
                  style: TextStyle(color: Colors.white),
                ),
                value: _transcriptVisible,
                onChanged: (val) {
                  setState(() => _transcript = val);
                  setModalState(() {});
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showVoiceAndSpeedSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _adobeSheetBg,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => AnimatedBuilder(
        animation: _playback,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Read aloud voice & speed',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'PLAYBACK SPEED',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final speed in const [
                    0.75,
                    0.9,
                    1.0,
                    1.1,
                    1.25,
                    1.5,
                    2.0,
                  ])
                    ChoiceChip(
                      selected: (_playback.speed - speed).abs() < 0.01,
                      label: Text('${speed}x'),
                      onSelected: (_) => _playback.setSpeed(speed),
                    ),
                ],
              ),
              const Divider(height: 24, color: Colors.white12),
              const Text(
                'AUDIO SOURCE',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    selected: !_playback.isOffline,
                    label: const Text('Server Stream'),
                    avatar: const Icon(Icons.cloud_outlined, size: 16),
                    onSelected: (_) => _switchSource('server'),
                  ),
                  ChoiceChip(
                    selected: _playback.usesSavedServer,
                    label: const Text('Saved Server Audio'),
                    avatar: const Icon(Icons.offline_pin_rounded, size: 16),
                    onSelected: (_) => _switchSource('saved-server'),
                  ),
                  ChoiceChip(
                    selected: _playback.isOffline && !_playback.usesSavedServer,
                    label: const Text('Phone Kokoro TTS'),
                    avatar: const Icon(Icons.phone_android, size: 16),
                    onSelected: (_) => _switchSource('phone'),
                  ),
                ],
              ),
              if (_playback.isOffline && !_playback.usesSavedServer) ...[
                const SizedBox(height: 14),
                const Text(
                  'PHONE OFFLINE VOICE',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in offlineVoices.entries)
                      ChoiceChip(
                        selected: _playback.offlineVoice == v.key,
                        label: Text(v.value),
                        onSelected: (_) => _playback.setOfflineVoice(v.key),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Adobe Acrobat Reader Android-style overflow bottom sheet (Screenshot 1),
  /// containing only features relevant to OpenReader.
  Future<void> _showAdobeMoreSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _adobeSheetBg,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) {
          final isBookmarked = _bookmarks.contains(_page);
          return SingleChildScrollView(
            padding: const EdgeInsets.only(top: 10, bottom: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${widget.document['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xffd9232e),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'PDF',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Page $_page of $_effectiveMaxPages  •  ${_playback.voice}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: isBookmarked
                            ? 'Remove bookmark on page $_page'
                            : 'Bookmark page $_page',
                        onPressed: () async {
                          await _toggleBookmark(_page);
                          setModalState(() {});
                        },
                        icon: Icon(
                          isBookmarked
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: isBookmarked
                              ? const Color(0xff4da3ff)
                              : Colors.white70,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                _adobeMenuTile(
                  icon: Icons.visibility_outlined,
                  title: 'View settings',
                  trailingChevron: true,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_showViewSettingsSheet());
                  },
                ),
                _adobeMenuTile(
                  icon: Icons.grid_view_rounded,
                  title: 'Pages',
                  trailingChevron: true,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_showNavigationSheet(initialTab: 1));
                  },
                ),
                _adobeMenuTile(
                  icon: Icons.bookmarks_outlined,
                  title: 'Bookmarks & Table of Contents',
                  trailingChevron: true,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_showNavigationSheet(initialTab: 0));
                  },
                ),
                _adobeMenuTile(
                  icon: isBookmarked
                      ? Icons.bookmark_remove_outlined
                      : Icons.bookmark_add_outlined,
                  title: isBookmarked
                      ? 'Remove bookmark (Page $_page)'
                      : 'Add bookmark (Page $_page)',
                  onTap: () async {
                    await _toggleBookmark(_page);
                    setModalState(() {});
                  },
                ),
                _adobeMenuTile(
                  icon: Icons.headphones_outlined,
                  title: _playback.wantedPlaying
                      ? 'Pause read aloud'
                      : 'Read aloud from this page',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (_playback.wantedPlaying) {
                      unawaited(_playback.toggle());
                    } else {
                      unawaited(_readPage(_page));
                    }
                  },
                ),
                _adobeMenuTile(
                  icon: Icons.record_voice_over_outlined,
                  title: 'Voice & playback speed (${_playback.speed}x)',
                  trailingChevron: true,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_showVoiceAndSpeedSheet());
                  },
                ),
                _adobeMenuTile(
                  tileKey: const Key('save-offline'),
                  icon: Icons.offline_pin_outlined,
                  title: _savingOffline
                      ? 'Saving offline...'
                      : 'Save PDF for offline reading',
                  enabled:
                      !_savingOffline &&
                      _pdfBytes != null &&
                      _playback.connected,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_saveOffline(prepareAudio: false));
                  },
                ),
                _adobeMenuTile(
                  icon: Icons.download_for_offline_outlined,
                  title: 'Prepare / Download full PDF audio',
                  enabled:
                      !_savingOffline &&
                      _pdfBytes != null &&
                      _playback.connected,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_saveOffline(prepareAudio: true));
                  },
                ),
                _adobeMenuTile(
                  icon: Icons.fullscreen_rounded,
                  title: 'Fullscreen reading mode',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_setFullscreen(true));
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _adobeMenuTile({
    Key? tileKey,
    required IconData icon,
    required String title,
    bool trailingChevron = false,
    bool enabled = true,
    required VoidCallback onTap,
  }) => ListTile(
    key: tileKey,
    enabled: enabled,
    contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 2),
    leading: Icon(
      icon,
      color: enabled ? Colors.white : Colors.white38,
      size: 24,
    ),
    title: Text(
      title,
      style: TextStyle(
        color: enabled ? Colors.white : Colors.white38,
        fontSize: 16,
        fontWeight: FontWeight.w400,
      ),
    ),
    trailing: trailingChevron
        ? const Icon(Icons.chevron_right_rounded, color: Colors.white70)
        : null,
    onTap: enabled ? onTap : null,
  );

  Future<void> _saveOffline({bool prepareAudio = false}) async {
    if (_savingOffline || _pdfBytes == null || _playback.payload == null) {
      return;
    }
    if (prepareAudio && _savedDocument != null) {
      await _playback.pause();
      if (!mounted) return;
      await showPrepareAudio(
        context,
        _savedDocument!,
        widget.preferences.getString('offlineVoice') ?? 'am_michael',
      );
      if (mounted) await _activateSavedAudioIfReady(_savedDocument!);
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
        if (mounted) await _activateSavedAudioIfReady(saved);
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

  Future<void> _switchSource(String source) async {
    final currentSource = _playback.usesSavedServer
        ? 'saved-server'
        : _playback.isOffline
        ? 'phone'
        : 'server';
    if (_switchingSource || source == currentSource) return;
    final phone = source != 'server';
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
        savedServerAudio: source == 'saved-server',
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
      if (saved != null &&
          !await widget.preferences.setString(
            'offline-source:${saved.key}',
            source == 'saved-server' ? 'server' : 'phone',
          )) {
        throw const ReaderException(
          'Could not save your audio source preference.',
        );
      }
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

  Widget _sourceButton() => PopupMenuButton<String>(
    key: const Key('voice-source'),
    tooltip: 'Choose phone, saved server, or live server audio',
    enabled: !_switchingSource,
    onSelected: _switchSource,
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: 'phone',
        checked: _playback.isOffline && !_playback.usesSavedServer,
        child: const Text('Phone / offline'),
      ),
      CheckedPopupMenuItem(
        value: 'saved-server',
        checked: _playback.usesSavedServer,
        child: const Text('Saved server / offline'),
      ),
      CheckedPopupMenuItem(
        value: 'server',
        checked: !_playback.isOffline,
        child: const Text('Server'),
      ),
    ],
    icon: Icon(
      _playback.usesSavedServer
          ? Icons.offline_pin_rounded
          : _playback.isOffline
          ? Icons.phone_android
          : Icons.cloud_outlined,
      color: Colors.white,
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
    icon: Icon(
      _pdfDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      color: Colors.white,
    ),
  );

  Widget _fullscreenButtons() => Positioned(
    top: 0,
    right: 0,
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: _adobeBarBg.withValues(alpha: 0.92),
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
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _playback.wantedPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                ),
              ),
              IconButton(
                key: const Key('exit-fullscreen'),
                tooltip: 'Exit fullscreen',
                onPressed: _changingFullscreen
                    ? null
                    : () => _setFullscreen(false),
                icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _scrollPillHideTimer?.cancel();
    _viewer.removeListener(_onViewerScrolled);
    _searchController.dispose();
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

  Widget _buildSearchBar() => Material(
    color: _adobeSheetBg,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Find in PDF...',
                hintStyle: const TextStyle(color: Colors.white54),
                isDense: true,
                prefixIcon: const Icon(
                  Icons.search,
                  size: 20,
                  color: Colors.white70,
                ),
                suffixText: _searchMatches.isEmpty
                    ? (_searchController.text.isEmpty ? '' : '0/0')
                    : '${_searchIndex + 1}/${_searchMatches.length}',
                suffixStyle: const TextStyle(color: Colors.white70),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              onChanged: _runSearch,
              onSubmitted: (_) => _jumpToSearchMatch(_searchIndex + 1),
            ),
          ),
          IconButton(
            tooltip: 'Previous match',
            onPressed: _searchMatches.isNotEmpty
                ? () => _jumpToSearchMatch(_searchIndex - 1)
                : null,
            icon: const Icon(Icons.keyboard_arrow_up, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Next match',
            onPressed: _searchMatches.isNotEmpty
                ? () => _jumpToSearchMatch(_searchIndex + 1)
                : null,
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Close search',
            onPressed: () => setState(() {
              _searching = false;
              _searchController.clear();
              _searchMatches = [];
            }),
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    ),
  );

  Widget _buildReflowView() => AnimatedBuilder(
    animation: _playback,
    builder: (context, _) {
      final pageSegments = _playback.plan
          .where((s) => integer(object(s['locator'])['page'], 1) == _page)
          .toList();
      final list = pageSegments.isNotEmpty ? pageSegments : _playback.plan;
      final word = _playback.activeWord;
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: _adobeSheetBg,
            child: Row(
              children: [
                const Icon(
                  Icons.water_drop_outlined,
                  size: 18,
                  color: Color(0xff4da3ff),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Liquid Mode — Page $_page (${pageSegments.length} passages)',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Smaller text',
                  onPressed: _reflowFontSize > 13
                      ? () {
                          setState(() => _reflowFontSize -= 2);
                          unawaited(
                            widget.preferences.setDouble(
                              'reflowFontSize',
                              _reflowFontSize,
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(
                    Icons.text_decrease,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Larger text',
                  onPressed: _reflowFontSize < 30
                      ? () {
                          setState(() => _reflowFontSize += 2);
                          unawaited(
                            widget.preferences.setDouble(
                              'reflowFontSize',
                              _reflowFontSize,
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(
                    Icons.text_increase,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification) {
                  _revealScrollPill();
                }
                return false;
              },
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                itemBuilder: (context, index) {
                  final seg = list[index];
                  final ord = integer(seg['ordinal']);
                  final text = '${seg['text'] ?? ''}';
                  final isCurrent = ord == _playback.currentOrdinal;
                  final start = isCurrent ? (word?.start ?? -1) : -1;
                  final end = isCurrent ? (word?.end ?? -1) : -1;
                  return Card(
                    elevation: isCurrent ? 3 : 0,
                    margin: const EdgeInsets.only(bottom: 10),
                    color: isCurrent
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerLowest,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => unawaited(_playback.startAt(ord)),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text.rich(
                          TextSpan(
                            children:
                                start >= 0 && end > start && end <= text.length
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
                                : [TextSpan(text: text)],
                          ),
                          style: TextStyle(
                            fontSize: _reflowFontSize,
                            height: 1.55,
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    },
  );

  /// Adobe Acrobat Reader Android-style right-edge black scroll pill + center
  /// page indicator overlay (Screenshots 2 & 3).
  /// Only appears when scrolling the document or while grabbing the pill.
  Widget _buildAdobeScrollOverlay(BuildContext viewportContext, BoxConstraints viewportConstraints) {
    final maxPages = _effectiveMaxPages;
    final activePage = (_dragTargetPage ?? _page).clamp(1, maxPages);
    final showPill =
        (_scrollPillVisible || _draggingScrollPill) && maxPages > 1;
    const pillHeight = 40.0;
    const topMargin = 14.0;
    const bottomMargin = 14.0;
    final usableTrack = math.max(
      1.0,
      viewportConstraints.maxHeight - pillHeight - topMargin - bottomMargin,
    );
    final fraction = maxPages > 1
        ? ((activePage - 1) / (maxPages - 1)).clamp(0.0, 1.0)
        : 0.0;
    final pillTop = topMargin + fraction * usableTrack;

    void scrubAtLocalDy(double dy) {
      final ratio = ((dy - topMargin - pillHeight / 2) / usableTrack).clamp(
        0.0,
        1.0,
      );
      final target = (1 + (ratio * (maxPages - 1)).round()).clamp(1, maxPages);
      if (_dragTargetPage != target) {
        setState(() {
          _dragTargetPage = target;
          _page = target;
        });
        if (_viewerLaidOut && _viewer.isReady && target <= _viewer.pageCount) {
          unawaited(
            _viewer.goToPage(pageNumber: target, duration: Duration.zero),
          );
        }
      }
    }

    return Stack(
      children: [
        // Center dark rounded square indicator ("196 / of 329") shown while scrubbing
        if (_draggingScrollPill)
          Center(
            child: IgnorePointer(
              child: Container(
                width: 118,
                height: 118,
                decoration: BoxDecoration(
                  color: const Color(0xf0222225),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 14,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$activePage',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(width: 72, height: 1, color: Colors.white38),
                    const SizedBox(height: 6),
                    Text(
                      'of $maxPages',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Right-edge black pill tab ("142" / "199") — only visible while scrolling/dragging
        Positioned(
          top: pillTop,
          right: 0,
          child: IgnorePointer(
            ignoring: !showPill,
            child: AnimatedOpacity(
              opacity: showPill ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _choosePage,
                onVerticalDragStart: (details) {
                  _scrollPillHideTimer?.cancel();
                  setState(() {
                    _draggingScrollPill = true;
                    _scrollPillVisible = true;
                    _dragTargetPage = _page;
                  });
                },
                onVerticalDragUpdate: (details) {
                  final box = viewportContext.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(details.globalPosition);
                  scrubAtLocalDy(local.dy);
                },
                onVerticalDragEnd: (_) {
                  final finalPage = _dragTargetPage ?? _page;
                  setState(() {
                    _draggingScrollPill = false;
                    _dragTargetPage = null;
                  });
                  unawaited(_goTo(finalPage, duration: Duration.zero));
                  _scheduleHideScrollPill();
                },
                onVerticalDragCancel: () {
                  setState(() {
                    _draggingScrollPill = false;
                    _dragTargetPage = null;
                  });
                  _scheduleHideScrollPill();
                },
                child: Container(
                  height: pillHeight,
                  padding: const EdgeInsets.fromLTRB(18, 8, 14, 8),
                  decoration: const BoxDecoration(
                    color: Color(0xf21e1e21),
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(22),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 6,
                        offset: Offset(-1, 2),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$activePage',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_fullscreen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _fullscreen) unawaited(_setFullscreen(false));
    },
    child: Scaffold(
      backgroundColor: _activeBackgroundColor,
      appBar: _fullscreen
          ? null
          : AppBar(
              backgroundColor: _adobeBarBg,
              foregroundColor: Colors.white,
              elevation: 0,
              leadingWidth: 64,
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  Container(width: 1, height: 22, color: Colors.white24),
                ],
              ),
              title: Text(
                '${widget.document['name']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              actions: [
                // Adobe Liquid / Reflow Mode icon
                IconButton(
                  tooltip: _reflowMode
                      ? 'Switch to PDF Page View'
                      : 'Liquid Reading Mode',
                  isSelected: _reflowMode,
                  onPressed: () => setState(() => _reflowMode = !_reflowMode),
                  icon: Icon(
                    Icons.water_drop_outlined,
                    color: _reflowMode
                        ? const Color(0xff4da3ff)
                        : Colors.white,
                  ),
                ),
                // Adobe Headphones (Read Aloud) icon
                AnimatedBuilder(
                  animation: _playback,
                  builder: (context, _) => IconButton(
                    tooltip: _playback.wantedPlaying
                        ? 'Pause Read Aloud'
                        : 'Read Aloud',
                    onPressed:
                        !_playback.connected ||
                            _playback.preparing ||
                            _switchingSource
                        ? null
                        : _playback.toggle,
                    icon: Icon(
                      Icons.headphones_outlined,
                      color: _playback.wantedPlaying
                          ? const Color(0xff4da3ff)
                          : Colors.white,
                    ),
                  ),
                ),
                // Search icon
                IconButton(
                  tooltip: 'Search in PDF',
                  isSelected: _searching,
                  onPressed: () => setState(() => _searching = !_searching),
                  icon: Icon(
                    Icons.search_rounded,
                    color: _searching ? const Color(0xff4da3ff) : Colors.white,
                  ),
                ),
                _darkPageButton(),
                _sourceButton(),
                IconButton(
                  key: const Key('enter-fullscreen'),
                  tooltip: 'Fullscreen PDF',
                  onPressed: _changingFullscreen
                      ? null
                      : () => _setFullscreen(true),
                  icon: const Icon(Icons.fullscreen, color: Colors.white),
                ),
                // Adobe-style rounded square ⋮ overflow button
                Padding(
                  padding: const EdgeInsets.only(right: 8, left: 2),
                  child: InkWell(
                    key: const Key('reader-menu'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: _showAdobeMoreSheet,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: _adobeButtonBg,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
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
                if (_searching && !_fullscreen) _buildSearchBar(),
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
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
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
                          : _reflowMode
                          ? _buildReflowView()
                          : (_pdfWidget ??
                                const Center(
                                  child: CircularProgressIndicator(),
                                ));
                      return Flex(
                        direction: wide ? Axis.horizontal : Axis.vertical,
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, pdfBox) => Stack(
                                children: [
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      key: const Key('pdf-surface'),
                                      child: pdf,
                                    ),
                                  ),
                                  _buildAdobeScrollOverlay(context, pdfBox),
                                ],
                              ),
                            ),
                          ),
                          if (_transcriptVisible)
                            SizedBox(
                              width: wide ? 280 : null,
                              height: wide ? null : 155,
                              child: _transcriptPanel(),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                if (!_fullscreen)
                  const SizedBox.shrink(key: Key('page-controls')),
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
      return Container(
        color: _adobeSheetBg,
        child: SingleChildScrollView(
          key: const Key('now-reading-panel'),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'NOW READING',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Page $_page / $_effectiveMaxPages',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 10),
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
                      : [
                          TextSpan(
                            text: text.isEmpty ? _playback.status : text,
                          ),
                        ],
                ),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  String _formatMs(int ms) {
    if (ms <= 0) return '0:00';
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// Sleek Adobe Acrobat Reader Android-style dark bottom bar (Screenshots 2 & 3),
  /// with OpenReader-relevant tools (Read aloud, Read page, Transcript, Pages, More tools)
  /// and a compact audio scrubber row when narration is active.
  Widget _controls() => AnimatedBuilder(
    animation: _playback,
    builder: (context, _) {
      final totalPassages = _playback.plan.length;
      final currentOrd = (_scrubPassage?.round() ?? _playback.currentOrdinal)
          .clamp(0, math.max(0, totalPassages - 1));
      final totalDurationMs = _playback.durationMs;
      final showAudioScrubber =
          _playback.wantedPlaying ||
          _playback.preparing ||
          _playback.error != null ||
          _scrubPassage != null;

      return Material(
        key: const Key('playback-bar'),
        color: _adobeBarBg,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_playback.preparing)
              const LinearProgressIndicator(
                minHeight: 2,
                color: Color(0xff4da3ff),
                backgroundColor: Colors.white12,
              )
            else
              Container(height: 1, color: Colors.white12),

            // Hidden/compact status key preserved for test compatibility and error display
            if (showAudioScrubber)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 28,
                          ),
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
                                      _playback.startAt(
                                        integer(previous['ordinal']),
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(
                            Icons.skip_previous_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        Text(
                          totalDurationMs > 0
                              ? _formatMs(_playback.currentMs)
                              : '${currentOrd + 1}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2.0,
                              activeTrackColor: const Color(0xff4da3ff),
                              inactiveTrackColor: Colors.white24,
                              thumbColor: const Color(0xff4da3ff),
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                            ),
                            child: Slider(
                              min: 0,
                              max: math.max(1, totalPassages - 1).toDouble(),
                              value: currentOrd
                                  .clamp(0, math.max(1, totalPassages - 1))
                                  .toDouble(),
                              onChanged:
                                  !_playback.connected ||
                                      _playback.preparing ||
                                      _switchingSource ||
                                      totalPassages <= 1
                                  ? null
                                  : (value) =>
                                        setState(() => _scrubPassage = value),
                              onChangeEnd: (value) {
                                final targetOrd = value.round();
                                setState(() => _scrubPassage = null);
                                if (_playback.wantedPlaying) {
                                  unawaited(_playback.startAt(targetOrd));
                                } else {
                                  unawaited(_playback.selectAt(targetOrd));
                                }
                              },
                            ),
                          ),
                        ),
                        Text(
                          totalDurationMs > 0
                              ? _formatMs(totalDurationMs)
                              : '$totalPassages',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 28,
                          ),
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
                                      _playback.startAt(
                                        integer(next['ordinal']),
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(
                            Icons.skip_next_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _showVoiceAndSpeedSheet,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _adobeButtonBg,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_playback.speed}x',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _switchingSource
                          ? 'Switching voice source...'
                          : _playback.status,
                      key: const Key('playback-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: _playback.error != null
                            ? Colors.redAccent
                            : Colors.white54,
                      ),
                    ),
                  ],
                ),
              )
            else
              Offstage(
                offstage: true,
                child: Text(
                  _playback.status,
                  key: const Key('playback-status'),
                ),
              ),

            // Main Adobe Acrobat Reader Android-style 5-item bottom bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _adobeBottomBarItem(
                    itemKey: const Key('play-pause'),
                    icon: _playback.wantedPlaying
                        ? Icons.pause_circle_outline_rounded
                        : Icons.headphones_outlined,
                    label: _playback.error != null
                        ? 'Retry'
                        : _playback.wantedPlaying
                        ? 'Pause'
                        : 'Read aloud',
                    active: _playback.wantedPlaying,
                    enabled:
                        _playback.connected &&
                        !_playback.preparing &&
                        !_switchingSource,
                    onTap: _playback.toggle,
                  ),
                  _adobeBottomBarItem(
                    icon: Icons.play_lesson_outlined,
                    label: 'Read page',
                    enabled: _playback.connected && !_playback.preparing,
                    onTap: () => _readPage(_page),
                  ),
                  _adobeBottomBarItem(
                    itemKey: const Key('toggle-transcript'),
                    icon: Icons.subtitles_outlined,
                    label: 'Transcript',
                    active: _transcriptVisible,
                    onTap: () =>
                        setState(() => _transcript = !_transcriptVisible),
                  ),
                  _adobeBottomBarItem(
                    icon: Icons.grid_view_rounded,
                    label: 'Pages',
                    onTap: () => _showNavigationSheet(initialTab: 1),
                  ),
                  _adobeBottomBarItem(
                    icon: Icons.more_horiz_rounded,
                    label: 'More tools',
                    onTap: _showAdobeMoreSheet,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _adobeBottomBarItem({
    Key? itemKey,
    required IconData icon,
    required String label,
    bool active = false,
    bool enabled = true,
    required VoidCallback onTap,
  }) {
    final color = !enabled
        ? Colors.white38
        : active
        ? const Color(0xff4da3ff)
        : Colors.white;
    return Expanded(
      child: InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
