import 'api.dart';

class HighlightWord {
  const HighlightWord({
    required this.text,
    required this.start,
    required this.end,
    required this.page,
    required this.ordinal,
    required this.wordIndex,
  });
  final String text;
  final int start;
  final int end;
  final int page;
  final int ordinal;
  final int wordIndex;
}

HighlightWord? wordAt(List<Json> timeline, int milliseconds) {
  for (final segment in timeline) {
    final start = integer(segment['startMs']);
    if (milliseconds < start || milliseconds >= integer(segment['endMs'])) {
      continue;
    }
    final alignment = object(segment['alignment']);
    final words = objects(alignment['words']);
    final seconds = (milliseconds - start) / 1000;
    for (var i = words.length - 1; i >= 0; i--) {
      final word = words[i];
      final from = (word['startSec'] as num?)?.toDouble() ?? 0;
      if (seconds >= from) {
        return HighlightWord(
          text: word['text'] as String? ?? '',
          start: integer(word['charStart'], -1),
          end: integer(word['charEnd'], -1),
          page: integer(object(segment['locator'])['page'], 1),
          ordinal: integer(segment['ordinal']),
          wordIndex: i,
        );
      }
    }
  }
  return null;
}

List<Json> mergeTimeline(List<Json> previous, List<Json> incoming) {
  final updates = {
    for (final segment in incoming) integer(segment['ordinal']): segment,
  };
  final held = {
    for (final segment in previous) integer(segment['ordinal']): segment,
  };
  final ordinals = {...held.keys, ...updates.keys}.toList()..sort();
  var cursor = 0;
  final merged = <Json>[];
  for (final ordinal in ordinals) {
    final old = held[ordinal];
    var row = updates[ordinal] ?? old!;
    if (old != null &&
        old['generated'] == true &&
        (row['generated'] != true ||
            old['alignment'] != null && row['alignment'] == null)) {
      row = old;
    }
    final duration = integer(row['durationMs']);
    final start = cursor;
    cursor += duration > 0 ? duration : 0;
    merged.add({...row, 'startMs': start, 'endMs': cursor});
  }
  return merged;
}

/// Keep original UTF-16 indices while matching across PDF line wraps.
class NormalizedText {
  NormalizedText(String source) {
    final buffer = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      final expanded = _ligatures[source[i]] ?? source[i].toLowerCase();
      for (var j = 0; j < expanded.length; j++) {
        final c = expanded[j];
        if (_letters.hasMatch(c)) {
          buffer.write(c);
          indices.add(i);
        }
      }
    }
    text = buffer.toString();
  }
  late final String text;
  final List<int> indices = [];
  static final _letters = RegExp(r'[a-z0-9\u00c0-\u024f]');
  static const _ligatures = {
    'ﬀ': 'ff',
    'ﬁ': 'fi',
    'ﬂ': 'fl',
    'ﬃ': 'ffi',
    'ﬄ': 'ffl',
  };
}

({int start, int end})? findWordRange(
  String pageText,
  String segmentText,
  HighlightWord word, {
  int searchStart = 0,
}) {
  final page = NormalizedText(pageText);
  final segment = NormalizedText(segmentText);
  final needle = NormalizedText(word.text).text;
  if (needle.isEmpty || segment.text.isEmpty) return null;
  final segmentStart = page.text.indexOf(segment.text, searchStart);
  if (segmentStart < 0) return null;
  int inSegment;
  int length;
  if (word.start >= 0 &&
      word.end > word.start &&
      word.end <= segmentText.length) {
    inSegment = NormalizedText(segmentText.substring(0, word.start))
        .text
        .length;
    length = NormalizedText(segmentText.substring(word.start, word.end))
        .text
        .length;
  } else {
    // Do not guess which occurrence to paint without character offsets.
    final first = segment.text.indexOf(needle);
    if (first < 0 || segment.text.indexOf(needle, first + 1) >= 0) return null;
    inSegment = first;
    length = needle.length;
  }
  final from = segmentStart + inSegment;
  final until = from + length - 1;
  if (length == 0 || from < 0 || until >= page.indices.length) return null;
  return (start: page.indices[from], end: page.indices[until] + 1);
}
