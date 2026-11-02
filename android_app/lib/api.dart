import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;

Json object(Object? value) => value is Map<String, dynamic>
    ? value
    : value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      }
    : {};
List<Json> objects(Object? value) =>
    value is List ? value.map(object).toList() : [];
int integer(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

class ReaderException implements Exception {
  const ReaderException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OpenReaderApi {
  OpenReaderApi(this.base, {http.Client? client}) {
    if (client != null) _client = client;
  }

  final Uri base;
  http.Client? _client;
  http.Client get _transport => _client ??= http.Client();
  final _storage = const FlutterSecureStorage();
  String _cookie = '';
  String get _storageKey => 'session:${base.origin}';

  static Uri parseServer(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const ReaderException(
        'Enter the server address, for example https://reader.example.com',
      );
    }
    return Uri.parse(uri.origin);
  }

  Future<bool> restore() async {
    _cookie = await _storage.read(key: _storageKey) ?? '';
    return _cookie.isNotEmpty;
  }

  Future<void> signIn(String email, String password) async {
    final response = await _transport
        .post(
          base.resolve('/api/auth/sign-in/email'),
          headers: {'Content-Type': 'application/json', 'Origin': base.origin},
          body: jsonEncode({
            'email': email.trim(),
            'password': password,
            'rememberMe': true,
          }),
        )
        .timeout(const Duration(seconds: 30));
    _check(response);
    final raw = response.headers['set-cookie'] ?? '';
    // Expires attributes contain commas; only split at the next cookie name.
    final cookies = raw
        .split(RegExp(r',(?=\s*[^;,\s=]+=)'))
        .map((cookie) => cookie.split(';').first.trim())
        .where((cookie) => cookie.isNotEmpty)
        .toList();
    if (cookies.isEmpty) {
      throw const ReaderException('The server did not create a login session.');
    }
    _cookie = cookies.join('; ');
    await _storage.write(key: _storageKey, value: _cookie);
  }

  Map<String, String> get _headers => {
    'Cookie': _cookie,
    'Origin': base.origin,
    'Content-Type': 'application/json',
  };

  Future<Json> get(String path) => _json('GET', path);
  Future<Json> post(String path, [Json? body]) => _json('POST', path, body);

  Future<bool> downloadAudio(
    String url,
    File destination, {
    required bool Function() canceled,
    required void Function(int received, int? total) onProgress,
  }) async {
    var uri = base.resolve(url);
    if (uri.origin != base.origin) {
      throw const ReaderException('Audio downloads must start at your server.');
    }
    final partial = File('${destination.path}.part');
    final validator = File('${destination.path}.etag');
    final etag = await validator.exists() ? await validator.readAsString() : '';
    var offset = await partial.exists() && etag.startsWith('"')
        ? await partial.length()
        : 0;
    for (var redirects = 0; redirects < 5; redirects++) {
      if (canceled()) return false;
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['Accept-Encoding'] = 'identity';
      if (uri.origin == base.origin) request.headers['Cookie'] = _cookie;
      if (offset > 0) {
        request.headers['Range'] = 'bytes=$offset-';
        request.headers['If-Range'] = etag;
      }
      final response = await _transport
          .send(request)
          .timeout(const Duration(seconds: 60));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.drain<void>();
        final location = response.headers['location'];
        if (location == null) {
          throw const ReaderException('Missing audio redirect.');
        }
        final next = uri.resolve(location);
        if (!['http', 'https'].contains(next.scheme) ||
            next.userInfo.isNotEmpty ||
            uri.scheme == 'https' && next.scheme != 'https') {
          throw const ReaderException('Unsafe audio download redirect.');
        }
        uri = next;
        continue;
      }
      if (response.statusCode == 416 && offset > 0) {
        await response.stream.drain<void>();
        offset = 0;
        continue;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        _check(await http.Response.fromStream(response));
        throw const ReaderException('Unexpected audio download response.');
      }
      int? total;
      if (response.statusCode == 206) {
        final range = RegExp(r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$')
            .firstMatch(response.headers['content-range'] ?? '');
        if (offset == 0 ||
            range == null ||
            int.parse(range[1]!) != offset ||
            response.headers['etag'] != etag ||
            int.parse(range[2]!) + 1 != int.parse(range[3]!)) {
          await response.stream.drain<void>();
          throw const ReaderException(
            'Invalid resumed audio download. Retry preparation.',
          );
        }
        total = int.parse(range[3]!);
      } else {
        offset = 0;
        total = response.contentLength;
      }
      final type = response.headers['content-type'] ?? '';
      if (type.contains('text/') || type.contains('json')) {
        await response.stream.drain<void>();
        throw const ReaderException(
          'The server did not return an audio recording.',
        );
      }
      final nextEtag = response.headers['etag'] ?? '';
      if (offset == 0) {
        await validator.writeAsString('', flush: true);
        await partial.writeAsBytes([], flush: true);
      }
      await validator.writeAsString(
        nextEtag.startsWith('"') ? nextEtag : '',
        flush: true,
      );
      final output = partial.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var received = offset;
      var flushed = received;
      try {
        await for (final bytes in response.stream.timeout(
          const Duration(seconds: 60),
        )) {
          if (canceled()) return false;
          received += bytes.length;
          if (received > 8 * 1024 * 1024 * 1024 ||
              total != null && received > total) {
            throw const ReaderException(
              'Audio exceeds the expected download size.',
            );
          }
          output.add(bytes);
          if (received - flushed >= 4 * 1024 * 1024) {
            await output.flush();
            flushed = received;
          }
          onProgress(received, total);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (received == 0 || total != null && received != total) {
        throw const ReaderException(
          'The audio download was interrupted. Resume preparation.',
        );
      }
      final signature = await partial.openRead(0, 3).first;
      if (signature.length < 3 ||
          !(signature[0] == 73 && signature[1] == 68 && signature[2] == 51 ||
              signature[0] == 255 && signature[1] & 224 == 224)) {
        await partial.delete();
        await validator.delete();
        throw const ReaderException(
          'The downloaded file is not an MP3 recording.',
        );
      }
      await partial.rename(destination.path);
      if (await validator.exists()) await validator.delete();
      return true;
    }
    throw const ReaderException('Too many audio download redirects.');
  }

  Future<Json> _json(String method, String path, [Json? body]) async {
    final uri = base.resolve(path);
    if (uri.origin != base.origin) {
      throw const ReaderException('Refusing to send login to another server.');
    }
    final response =
        await (method == 'GET'
                ? _transport.get(uri, headers: _headers)
                : _transport.post(
                    uri,
                    headers: _headers,
                    body: jsonEncode(body ?? {}),
                  ))
            .timeout(const Duration(seconds: 60));
    _check(response);
    if (response.body.isEmpty) return {};
    return object(jsonDecode(response.body));
  }

  Future<Uint8List> pdf(String id) async {
    var uri = base.resolve(
      '/api/documents/blob/get?id=${Uri.encodeQueryComponent(id)}',
    );
    for (var redirects = 0; redirects < 5; redirects++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      if (uri.origin == base.origin) request.headers['Cookie'] = _cookie;
      final streamed = await _transport
          .send(request)
          .timeout(const Duration(seconds: 60));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(minutes: 2));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) {
          throw const ReaderException('Missing PDF download redirect.');
        }
        final next = uri.resolve(location);
        if (!['http', 'https'].contains(next.scheme) ||
            (uri.scheme == 'https' && next.scheme != 'https')) {
          throw const ReaderException('Unsafe PDF download redirect.');
        }
        uri = next;
        continue;
      }
      _check(response);
      if (response.bodyBytes.length < 5 ||
          ascii.decode(response.bodyBytes.take(5).toList()) != '%PDF-') {
        throw const ReaderException('The server did not return a PDF file.');
      }
      return response.bodyBytes;
    }
    throw const ReaderException('Too many PDF download redirects.');
  }

  Future<Json> uploadPdf(Uint8List bytes, String name) async {
    final prepared = await post('/api/documents/blob/upload', {
      'uploads': [
        {'contentType': 'application/pdf', 'size': bytes.length},
      ],
    });
    final upload = objects(prepared['uploads']).firstOrNull;
    if (upload == null ||
        upload['url'] is! String ||
        upload['token'] is! String) {
      throw const ReaderException('The server did not prepare a PDF upload.');
    }
    final uri = base.resolve(upload['url'] as String);
    if (!['http', 'https'].contains(uri.scheme) ||
        base.scheme == 'https' && uri.scheme != 'https') {
      throw const ReaderException('Unsafe PDF upload URL.');
    }
    final headers = <String, String>{
      for (final entry in object(upload['headers']).entries)
        entry.key: entry.value as String,
      if (uri.origin == base.origin) 'Cookie': _cookie,
    };
    final response = await _transport
        .put(uri, headers: headers, body: bytes)
        .timeout(const Duration(minutes: 3));
    _check(response);
    final completed = await post('/api/documents/blob/upload/finalize', {
      'uploads': [
        {
          'token': upload['token'],
          'name': name,
          'type': 'pdf',
          'lastModified': DateTime.now().millisecondsSinceEpoch,
        },
      ],
    });
    final stored = objects(completed['stored']).firstOrNull;
    if (stored == null || stored['id'] is! String) {
      throw const ReaderException('The server did not save this PDF.');
    }
    return stored;
  }

  void _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401) {
      throw const ReaderException(
        'Session expired. Sign out and connect again.',
      );
    }
    String? message;
    try {
      final json = object(jsonDecode(response.body));
      final value = json['message'] ?? json['error'];
      if (value is String) message = value;
    } on FormatException {
      message = null;
    }
    throw ReaderException(
      message ?? 'OpenReader returned HTTP ${response.statusCode}.',
    );
  }

  Future<void> signOut() async {
    try {
      await post('/api/auth/sign-out');
    } finally {
      _cookie = '';
      await _storage.delete(key: _storageKey);
    }
  }

  void close() => _client?.close();
}
