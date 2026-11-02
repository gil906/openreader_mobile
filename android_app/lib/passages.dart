import 'dart:ui';

import 'alignment.dart';
import 'api.dart';

List<int> pdfWordGlyphs({
  required String pageText,
  required List<Rect> characterRects,
  required List<Rect> blockBounds,
  required String segmentText,
  required HighlightWord word,
}) {
  final indices = <int>[];
  final filtered = StringBuffer();
  for (var i = 0; i < pageText.length && i < characterRects.length; i++) {
    final rect = characterRects[i];
    if (blockBounds.isEmpty ||
        !rect.isEmpty &&
            blockBounds.any((box) => box.inflate(2).contains(rect.center))) {
      indices.add(i);
      filtered.write(pageText[i]);
    }
  }
  final text = filtered.toString();
  var range = findWordRange(text, segmentText, word);
  if (range == null && word.start >= 0 && word.end <= segmentText.length) {
    final words = RegExp(r'\S+').allMatches(segmentText).toList();
    final current = words.indexWhere(
      (token) => token.start <= word.start && token.end > word.start,
    );
    if (current >= 0) {
      final native = NormalizedText(text).text;
      for (var radius = 5; radius >= 0; radius--) {
        final start =
            words[(current - radius).clamp(0, words.length - 1)].start;
        final end = words[(current + radius).clamp(0, words.length - 1)].end;
        final context = segmentText.substring(start, end);
        final needle = NormalizedText(context).text;
        final first = native.indexOf(needle);
        if (needle.isEmpty ||
            first < 0 ||
            native.indexOf(needle, first + 1) >= 0) {
          continue;
        }
        range = findWordRange(
          text,
          context,
          HighlightWord(
            text: word.text,
            start: word.start - start,
            end: word.end - start,
            page: word.page,
            ordinal: word.ordinal,
            wordIndex: word.wordIndex,
          ),
        );
        if (range != null) break;
      }
    }
  }
  if (range == null) return [];
  return indices.sublist(range.start, range.end).toSet().toList();
}

int? matchingPassage(
  List<Json> target,
  Json previous,
  int page,
  HighlightWord? word,
) {
  final locator = object(previous['locator']);
  final oldText = NormalizedText(previous['text'] as String? ?? '').text;
  final candidates = target
      .where((row) => integer(object(row['locator'])['page'], 1) == page)
      .toList();
  Json? best;
  var bestScore = 0;
  for (final row in candidates) {
    final text = NormalizedText(row['text'] as String? ?? '').text;
    var score = 0;
    if (text.isNotEmpty && (text.contains(oldText) || oldText.contains(text))) {
      score += 100;
    }
    if (object(row['locator'])['blockId'] == locator['blockId']) score += 80;
    if (row['sourceOrdinal'] == previous['ordinal'] ||
        previous['sourceOrdinal'] == row['ordinal']) {
      score += 60;
    }
    final terms = RegExp(r'[a-z0-9]{3,}')
        .allMatches((previous['text'] as String? ?? '').toLowerCase())
        .map((match) => match.group(0)!)
        .toSet();
    score += terms.where(text.contains).length;
    if (word != null && text.contains(NormalizedText(word.text).text)) {
      score += 4;
    }
    if (score > bestScore) {
      best = row;
      bestScore = score;
    }
  }
  return bestScore >= 8 ? integer(best?['ordinal']) : null;
}

Json? passageAtPoint({
  required int page,
  required Offset point,
  required List<Json> pages,
  required List<Json> plan,
  String? pageText,
  List<Rect>? characterRects,
}) {
  final candidates = <({Rect bounds, List<Json> segments})>[];
  for (final parsedPage in pages) {
    for (final block in objects(parsedPage['blocks'])) {
      final segments = plan
          .where(
            (segment) => object(segment['locator'])['blockId'] == block['id'],
          )
          .toList();
      if (segments.isEmpty) continue;
      for (final fragment in objects(block['fragments'])) {
        if (integer(fragment['page']) != page) continue;
        final box = fragment['bbox'];
        if (box is! List || box.length != 4 || !box.every((v) => v is num)) {
          continue;
        }
        final bounds = Rect.fromLTRB(
          (box[0] as num).toDouble(),
          (box[1] as num).toDouble(),
          (box[2] as num).toDouble(),
          (box[3] as num).toDouble(),
        );
        if (!bounds.isEmpty && bounds.inflate(3).contains(point)) {
          candidates.add((bounds: bounds, segments: segments));
        }
      }
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final inside = (a.bounds.contains(point) ? 0 : 1).compareTo(
      b.bounds.contains(point) ? 0 : 1,
    );
    return inside != 0
        ? inside
        : (a.bounds.width * a.bounds.height).compareTo(
            b.bounds.width * b.bounds.height,
          );
  });
  final candidate = candidates.first;
  if (pageText != null && characterRects != null) {
    int? character;
    var closest = double.infinity;
    for (var i = 0; i < characterRects.length && i < pageText.length; i++) {
      final rect = characterRects[i];
      if (rect.isEmpty || !rect.overlaps(candidate.bounds)) continue;
      final dx = (point.dx - point.dx.clamp(rect.left, rect.right)).abs();
      final dy = (point.dy - point.dy.clamp(rect.top, rect.bottom)).abs();
      final distance = dx * dx + dy * dy;
      if (distance < closest) {
        closest = distance;
        character = i;
      }
    }
    if (character != null) {
      final text = NormalizedText(pageText);
      for (final segment in candidate.segments) {
        final needle = NormalizedText(segment['text'] as String? ?? '').text;
        if (needle.isEmpty) continue;
        var index = text.text.indexOf(needle);
        while (index >= 0) {
          final start = text.indices[index];
          final end = text.indices[index + needle.length - 1] + 1;
          if (character >= start && character < end) return segment;
          index = text.text.indexOf(needle, index + 1);
        }
      }
    }
  }
  return candidate.segments
          .where(
            (segment) => integer(object(segment['locator'])['page']) == page,
          )
          .firstOrNull ??
      candidate.segments.first;
}
