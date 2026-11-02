import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'offline_store.dart';
import 'reader.dart';

class IncomingPdfs {
  IncomingPdfs(this.navigator);
  final GlobalKey<NavigatorState> navigator;
  static const _channel = MethodChannel('com.homelab.openreader_native/reader');
  final _seen = <String>{};
  final _queue = <Json>[];
  bool _processing = false;

  void attach() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openPdf') _add(object(call.arguments));
      if (call.method == 'openPdfError') _showError('${call.arguments}');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pending = object(
          await _channel.invokeMapMethod<String, dynamic>('pendingPdfs'),
        );
        for (final pdf in objects(pending['pdfs'])) {
          _add(pdf);
        }
        for (final error in (pending['errors'] as List? ?? [])) {
          _showError('$error');
        }
        unawaited(_drain());
      } on MissingPluginException {
        // Non-Android widget tests have no activity channel.
      } on PlatformException catch (error) {
        _showError('Could not receive the selected PDF: ${error.message}');
      }
    });
  }

  void _showError(String error) {
    final context = navigator.currentContext;
    if (context != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _add(Json incoming) {
    if (incoming['id'] is! String || !_seen.add(incoming['id'] as String)) {
      return;
    }
    _queue.add(incoming);
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_processing || navigator.currentState == null) return;
    _processing = true;
    while (_queue.isNotEmpty) {
      final incoming = _queue.removeAt(0);
      final nav = navigator.currentState!;
      nav.popUntil((route) => route.isFirst);
      final progressRoute = MaterialPageRoute<void>(
        builder: (_) => const PopScope(
          canPop: false,
          child: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Importing selected PDF...'),
                ],
              ),
            ),
          ),
        ),
      );
      unawaited(nav.push(progressRoute));
      try {
        final store = await OfflineStore.open();
        final source = File(incoming['path'] as String);
        final document = await store.importPdf(
          await source.readAsBytes(),
          incoming['name'] as String? ?? 'Document.pdf',
          allowImageOnly: true,
        );
        final preferences = await SharedPreferences.getInstance();
        final api = OpenReaderApi(Uri.parse(document.origin));
        nav.removeRoute(progressRoute);
        unawaited(
          nav
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => ReaderPage(
                    api: api,
                    preferences: preferences,
                    document: document.document,
                    offline: document,
                  ),
                ),
              )
              .whenComplete(api.close),
        );
      } catch (error) {
        nav.removeRoute(progressRoute);
        _showError('Could not open this PDF: $error');
      } finally {
        try {
          await _channel.invokeMethod<void>('finishPdfImport', {
            'id': incoming['id'],
          });
        } on PlatformException catch (error) {
          debugPrint(
            'OpenReader: temporary PDF cleanup failed: ${error.message}',
          );
        }
      }
    }
    _processing = false;
  }
}
