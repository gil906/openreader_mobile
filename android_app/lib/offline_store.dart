import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'api.dart';

const offlinePackHash =
    'abaff9787f8b73c28dc2876c7610bcc162b0fc29cd6fa7556af72e20b8f9e8d7';
const offlinePackName = 'kokoro-english-v1.zip';

class OfflineDocument {
  const OfflineDocument(this.directory, this.metadata, this.payload);
  final Directory directory;
  final Json metadata;
  final Json payload;
  File get pdf => File(p.join(directory.path, 'document.pdf'));
  Json get document => object(metadata['document']);
  String get origin => metadata['origin'] as String;
  String get key => p.basename(directory.path);
  bool get importedOnPhone => !payload.containsKey('playback');
  Future<void> saveServerDocument(String origin, Json serverDocument) async {
    metadata['narrationServerDocument'] = {
      'origin': origin,
      'document': serverDocument,
    };
    final file = File(p.join(directory.path, 'document.json'));
    final partial = File('${file.path}.part');
    await partial.writeAsString(jsonEncode(metadata), flush: true);
    await partial.rename(file.path);
  }
}

class OfflineStore {
  OfflineStore(this.root);
  final Directory root;
  static Future<OfflineStore> open() async {
    final support = await getApplicationSupportDirectory();
    return OfflineStore(
      await Directory(p.join(support.path, 'offline')).create(recursive: true),
    );
  }

  Directory get pack => Directory(p.join(root.path, 'kokoro-v1'));
  Directory get audio => Directory(p.join(root.path, 'audio'));
  Future<bool> get packInstalled async {
    final ready = File(p.join(pack.path, 'ready'));
    return await ready.exists() &&
        await ready.readAsString() == offlinePackHash &&
        await File(p.join(pack.path, 'model.onnx')).exists() &&
        await File(p.join(pack.path, 'voices.bin')).exists();
  }

  Future<void> installPack(File zip, void Function(String) status) async {
    status('Checking voice pack integrity...');
    final actual = (await sha256.bind(zip.openRead()).first).toString();
    if (actual != offlinePackHash) {
      throw const ReaderException(
        'Voice pack checksum failed. Delete the download and try again.',
      );
    }
    status('Installing on-device voices...');
    await Isolate.run(() => _extractPack(zip.path, pack.path));
  }

  static void _extractPack(String zipPath, String destination) {
    final staging = Directory('$destination.installing');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input);
      var expanded = 0;
      for (final entry in archive) {
        final target = p.normalize(p.join(staging.path, entry.name));
        if (entry.isSymbolicLink || !p.isWithin(staging.path, target)) {
          throw const ReaderException('Unsafe voice pack entry.');
        }
        expanded += entry.size;
        if (expanded > 900 * 1024 * 1024) {
          throw const ReaderException('Voice pack is larger than expected.');
        }
        if (entry.isFile) {
          File(target).parent.createSync(recursive: true);
          final output = OutputFileStream(target);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
        } else {
          Directory(target).createSync(recursive: true);
        }
      }
      for (final name in [
        'model.onnx',
        'voices.bin',
        'tokens.txt',
        'lexicon-us-en.txt',
      ]) {
        if (!File(p.join(staging.path, name)).existsSync()) {
          throw ReaderException('Voice pack is missing $name.');
        }
      }
      File(p.join(staging.path, 'ready'))
          .writeAsStringSync(offlinePackHash, flush: true);
      final installed = Directory(destination);
      if (installed.existsSync()) installed.deleteSync(recursive: true);
      staging.renameSync(destination);
    } finally {
      input.closeSync();
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }

  Future<List<OfflineDocument>> documents() async {
    final directory = Directory(p.join(root.path, 'documents'));
    if (!await directory.exists()) return [];
    final result = <OfflineDocument>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(entry.path))) {
        continue;
      }
      final metadata = object(
        jsonDecode(
          await File(p.join(entry.path, 'document.json')).readAsString(),
        ),
      );
      final payload = object(
        jsonDecode(
          await File(p.join(entry.path, 'reader.json')).readAsString(),
        ),
      );
      if (!await File(p.join(entry.path, 'document.pdf')).exists()) {
        throw ReaderException(
          'Saved PDF is missing: ${object(metadata['document'])['name']}',
        );
      }
      result.add(OfflineDocument(entry, metadata, payload));
    }
    result.sort(
      (a, b) => '${a.document['name']}'.compareTo('${b.document['name']}'),
    );
    return result;
  }

  Future<OfflineDocument> save({
    required String origin,
    required String account,
    required Json document,
    required Json payload,
    required Uint8List bytes,
    bool allowImageOnly = false,
  }) async {
    if (!allowImageOnly &&
        objects(object(payload['plan'])['segments']).isEmpty) {
      throw const ReaderException('This PDF has no readable text to save.');
    }
    final key = sha256
        .convert(utf8.encode('$origin\n$account\n${document['id']}'))
        .toString();
    final directory = Directory(p.join(root.path, 'documents', key));
    final staging = Directory('${directory.path}.saving');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final metadata = <String, dynamic>{
      'origin': origin,
      'document': document,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    };
    try {
      await File(p.join(staging.path, 'document.pdf'))
          .writeAsBytes(bytes, flush: true);
      await File(p.join(staging.path, 'document.json'))
          .writeAsString(jsonEncode(metadata), flush: true);
      await File(p.join(staging.path, 'reader.json'))
          .writeAsString(jsonEncode(payload), flush: true);
      final backup = Directory('${directory.path}.previous');
      if (await backup.exists()) await backup.delete(recursive: true);
      if (await directory.exists()) await directory.rename(backup.path);
      try {
        await staging.rename(directory.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(directory.path);
        rethrow;
      }
      if (await backup.exists()) await backup.delete(recursive: true);
      return OfflineDocument(directory, metadata, payload);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> remove(OfflineDocument document) async {
    final expected = p.join(root.path, 'documents', document.key);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(document.key) ||
        p.normalize(document.directory.path) != p.normalize(expected)) {
      throw const ReaderException('Invalid saved document path.');
    }
    final narration = Directory(p.join(root.path, 'prepared', document.key));
    if (await narration.exists()) await narration.delete(recursive: true);
    final serverNarration = Directory(
      p.join(root.path, 'prepared_server', document.key),
    );
    if (await serverNarration.exists()) {
      await serverNarration.delete(recursive: true);
    }
    await document.directory.delete(recursive: true);
  }

  Future<OfflineDocument> importPdf(
    Uint8List bytes,
    String name, {
    bool allowImageOnly = false,
  }) async {
    await pdfrxFlutterInitialize();
    final pdf = await PdfDocument.openData(bytes);
    final pages = <Json>[];
    final segments = <Json>[];
    try {
      for (final page in pdf.pages) {
        final raw = await page.loadText();
        final blocks = <Json>[];
        if (raw != null) {
          final lines = RegExp(r'[^\r\n]+').allMatches(raw.fullText).toList();
          final groups = <({String text, Rect box})>[];
          var text = '';
          Rect? box;
          int? lastEnd;
          Rect? lastLine;
          void finish() {
            if (text.trim().isNotEmpty && box != null) {
              groups.add((text: text.trim(), box: box!));
            }
            text = '';
            box = null;
          }

          for (final line in lines) {
            Rect? lineBox;
            for (
              var i = line.start;
              i < line.end && i < raw.charRects.length;
              i++
            ) {
              final rect = raw.charRects[i].toRect(page: page);
              if (!rect.isEmpty) {
                lineBox = lineBox?.expandToInclude(rect) ?? rect;
              }
            }
            if (lineBox == null) continue;
            final gap = lastEnd == null
                ? ''
                : raw.fullText.substring(lastEnd, line.start);
            if (lastLine != null &&
                (RegExp(r'\n[\s\r]*\n').hasMatch(gap) ||
                    lineBox.top - lastLine.bottom > lastLine.height * .8 ||
                    lineBox.left > lastLine.right + 20 ||
                    lineBox.top < lastLine.top - 5)) {
              finish();
            }
            text = text.isEmpty ? line.group(0)! : '$text ${line.group(0)}';
            box = box?.expandToInclude(lineBox) ?? lineBox;
            lastLine = lineBox;
            lastEnd = line.end;
          }
          finish();
          for (final group in groups) {
            final blockId = 'local-${page.pageNumber}-${blocks.length}';
            blocks.add({
              'id': blockId,
              'text': group.text,
              'fragments': [
                {
                  'page': page.pageNumber,
                  'bbox': [
                    group.box.left,
                    group.box.top,
                    group.box.right,
                    group.box.bottom,
                  ],
                },
              ],
            });
            for (final chunk in offlineChunks(group.text)) {
              segments.add({
                'ordinal': segments.length,
                'text': chunk,
                'locator': {
                  'readerType': 'pdf',
                  'page': page.pageNumber,
                  'blockId': blockId,
                },
              });
            }
          }
        }
        pages.add({'pageNumber': page.pageNumber, 'blocks': blocks});
      }
    } finally {
      await pdf.dispose();
    }
    if (segments.isEmpty && !allowImageOnly) {
      throw const ReaderException(
        'No selectable text was found. Scanned PDFs need OCR before offline reading.',
      );
    }
    final id = sha256.convert(bytes).toString();
    final previous = (await documents())
        .where(
          (document) =>
              document.document['id'] == id && document.importedOnPhone,
        )
        .firstOrNull;
    return save(
      origin: previous?.origin ?? 'http://offline.example.test',
      account: 'local',
      document: {'id': id, 'name': name, 'type': 'pdf', 'size': bytes.length},
      payload: {
        'parsedDocument': {'pages': pages},
        'plan': {'segments': segments},
        'initialPosition': {'segmentOrdinal': 0},
      },
      bytes: bytes,
      allowImageOnly: allowImageOnly,
    );
  }
}

List<Json> buildOfflinePlan(Json payload) {
  final segments = <Json>[];
  for (final row in objects(object(payload['plan'])['segments'])) {
    for (final chunk in offlineChunks(row['text'] as String? ?? '')) {
      segments.add({
        ...row,
        'text': chunk,
        'ordinal': segments.length,
        'sourceOrdinal': row['ordinal'],
      });
    }
  }
  return segments;
}

List<String> offlineChunks(String text, {int limit = 280}) {
  final words = text.trim().split(RegExp(r'\s+'));
  final result = <String>[];
  var current = '';
  for (final original in words) {
    var word = original;
    while (word.length > limit) {
      if (current.isNotEmpty) {
        result.add(current);
        current = '';
      }
      result.add(word.substring(0, limit));
      word = word.substring(limit);
    }
    if (current.isNotEmpty && current.length + word.length + 1 > limit) {
      result.add(current);
      current = '';
    }
    current = current.isEmpty ? word : '$current $word';
    if (current.length >= limit ~/ 2 &&
        RegExp(
          r'[.!?]["'
          "'"
          r']?$',
        ).hasMatch(current)) {
      result.add(current);
      current = '';
    }
  }
  if (current.isNotEmpty) result.add(current);
  return result;
}
