import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'reader.dart';
import 'offline_library.dart';
import 'incoming_pdf.dart';

bool _voiceLicensesRegistered = false;
final _navigator = GlobalKey<NavigatorState>();
IncomingPdfs? _incoming;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_voiceLicensesRegistered) {
    _voiceLicensesRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        'eSpeak-NG / OpenReader Native',
      ], await rootBundle.loadString('assets/licenses/espeak-ng-GPL-3.0.txt'));
      yield LicenseEntryWithLineBreaks([
        'Kokoro-82M offline model',
      ], await rootBundle.loadString('assets/licenses/kokoro-Apache-2.0.txt'));
    });
  }
  runApp(const OpenReaderApp());
  _incoming ??= IncomingPdfs(_navigator)..attach();
}

class OpenReaderApp extends StatelessWidget {
  const OpenReaderApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenReader Native',
    navigatorKey: _navigator,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff126b64),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff69c8ba),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: const ConnectPage(),
  );
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});
  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _server = TextEditingController(
    text: const String.fromEnvironment('OPENREADER_DEFAULT_SERVER'),
  );
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = true;
  String? _error;
  bool _obscure = true;
  bool _offlineOpened = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    OpenReaderApi? api;
    try {
      final prefs = await SharedPreferences.getInstance();
      _server.text = prefs.getString('server') ?? _server.text;
      _email.text = prefs.getString('email') ?? _email.text;
      if (_server.text.trim().isEmpty) return;
      api = OpenReaderApi(OpenReaderApi.parseServer(_server.text));
      if (await api.restore()) {
        final documents = await api
            .get('/api/documents')
            .timeout(const Duration(seconds: 5));
        if (mounted &&
            !_offlineOpened &&
            !(_navigator.currentState?.canPop() ?? false)) {
          await _library(api, prefs, documents);
        }
      }
    } catch (exception) {
      if (mounted) setState(() => _error = _describe(exception));
    } finally {
      api?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your OpenReader email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    OpenReaderApi? api;
    try {
      api = OpenReaderApi(OpenReaderApi.parseServer(_server.text));
      await api.signIn(_email.text, _password.text);
      final documents = await api.get('/api/documents');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server', api.base.origin);
      await prefs.setString('email', _email.text.trim());
      _password.clear();
      if (mounted) await _library(api, prefs, documents);
    } catch (exception) {
      if (mounted) setState(() => _error = _describe(exception));
    } finally {
      api?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOffline() async {
    _offlineOpened = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OfflineLibraryPage(preferences: preferences),
        ),
      );
    } finally {
      _offlineOpened = false;
    }
  }

  Future<void> _library(
    OpenReaderApi api,
    SharedPreferences prefs,
    Json data,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LibraryPage(api: api, preferences: prefs, initial: data),
    ),
  );

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.auto_stories_rounded,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Your reading room',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Native PDFs. Natural voices. Follow every word.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    key: const Key('server'),
                    controller: _server,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'OpenReader server',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('email'),
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username],
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('password'),
                    controller: _password,
                    enabled: !_busy,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _busy ? null : _connect(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    key: const Key('connect'),
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(_busy ? 'Connecting...' : 'Connect to library'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('open-offline-library'),
                    onPressed: _openOffline,
                    icon: const Icon(Icons.offline_pin_outlined),
                    label: const Text('Offline library & voices'),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Server reading uses home Wi-Fi or VPN. Offline library uses '
                    'voices and PDFs saved on this phone. HTTP is for '
                    'trusted home networks only. Use HTTPS for remote access.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

String _describe(Object exception) => exception is ReaderException
    ? exception.message
    : 'Cannot connect. Check the server address, home Wi-Fi, and that your Lenovo is awake.';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.api,
    required this.preferences,
    required this.initial,
  });
  final OpenReaderApi api;
  final SharedPreferences preferences;
  final Json initial;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late List<Json> _documents;
  bool _busy = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _documents = objects(widget.initial['documents']);
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final data = await widget.api.get('/api/documents');
      if (mounted) {
        setState(() {
          _documents = objects(data['documents']);
          _error = null;
        });
      }
    } catch (exception) {
      if (mounted) setState(() => _error = _describe(exception));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await widget.api.signOut();
      if (mounted) Navigator.of(context).pop();
    } catch (exception) {
      if (mounted) {
        setState(
          () => _error =
              'Sign-out could not reach the server. '
              'Your saved session has been removed. Go back to reconnect.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final documents = _documents
        .where(
          (document) =>
              document['type'] == 'pdf' &&
              '${document['name']}'.toLowerCase().contains(
                _query.toLowerCase(),
              ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your library'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            key: const Key('open-offline-library'),
            tooltip: 'Offline library and voices',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    OfflineLibraryPage(preferences: widget.preferences),
              ),
            ),
            icon: const Icon(Icons.offline_pin_outlined),
          ),
          IconButton(
            tooltip: 'Refresh library',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _busy ? null : _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Find a PDF',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.home_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${widget.api.base.host}  /  ${documents.length} PDFs',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: documents.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No matching PDFs. Upload PDFs to your OpenReader server, '
                        'then refresh this library.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => RefreshIndicator(
                      onRefresh: _refresh,
                      child: GridView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: constraints.maxWidth >= 700 ? 2 : 1,
                          mainAxisExtent: 158,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: documents.length,
                        itemBuilder: (context, index) {
                          final document = documents[index];
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: Key('document-${document['id']}'),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => ReaderPage(
                                      api: widget.api,
                                      preferences: widget.preferences,
                                      document: document,
                                    ),
                                  ),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.picture_as_pdf_outlined,
                                      size: 44,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            '${document['name']}',
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                          const SizedBox(height: 10),
                                          const Text('Open & listen'),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
