class SpeechInput {
  const SpeechInput(this.text, {this.separator = false});
  final String text;
  final bool separator;
}

SpeechInput phoneSpeechInput(String original) {
  var text = original
      .replaceAll(
        RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]'),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty ||
      RegExp(r'^[\s•●○◦■□▪▫━─—–_…]+$').hasMatch(text) ||
      RegExp(r'^[-_=*~\s]{2,}$').hasMatch(text)) {
    return const SpeechInput('', separator: true);
  }
  const ligatures = {'ﬀ': 'ff', 'ﬁ': 'fi', 'ﬂ': 'fl', 'ﬃ': 'ffi', 'ﬄ': 'ffl'};
  for (final entry in ligatures.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  text = String.fromCharCodes(
    text.runes.map((rune) {
      if (rune >= 0xff10 && rune <= 0xff19) return rune - 0xff10 + 48;
      if (rune >= 0x660 && rune <= 0x669) return rune - 0x660 + 48;
      return rune;
    }),
  );
  text = text.replaceAllMapped(
    RegExp(r'(^|\s)-(?=\s*[0-9])'),
    (match) => '${match[1]}minus ',
  );
  if (text == '-') return const SpeechInput('minus');
  text = text.replaceAllMapped(
    RegExp(r'\b[0-9]{1,3}(?:\.[0-9]{1,3}){3}\b'),
    (match) => match[0]!.split('.').map(englishNumber).join(' dot '),
  );
  text = text.replaceAllMapped(
    RegExp(r'([0-9]+)\.([0-9]+)'),
    (match) =>
        '${englishNumber(match[1]!)} point ${match[2]!.split('').map(englishNumber).join(' ')}',
  );
  text = text.replaceAllMapped(
    RegExp(r'[0-9]+'),
    (match) => ' ${englishNumber(match[0]!)} ',
  );
  const operators = {
    '→': ' right arrow ',
    '←': ' left arrow ',
    '↔': ' bidirectional arrow ',
    '≤': ' less than or equal to ',
    '≥': ' greater than or equal to ',
    '=': ' equals ',
    '+': ' plus ',
    '/': ' slash ',
    '\\': ' backslash ',
    '|': ' vertical bar ',
    '<': ' less than ',
    '>': ' greater than ',
    '%': ' percent ',
    '&': ' and ',
    '@': ' at ',
    '×': ' times ',
    '−': ' minus ',
    '±': ' plus or minus ',
    '✓': ' check mark ',
    '✗': ' cross mark ',
  };
  for (final entry in operators.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text)) {
    return const SpeechInput('', separator: true);
  }
  return SpeechInput(text);
}

String englishNumber(String digits) {
  const units = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];
  const tens = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];
  if (!RegExp(r'^[0-9]+$').hasMatch(digits)) {
    throw ArgumentError.value(
      digits.length,
      'digits length',
      'Expected digits only',
    );
  }
  if (digits.length > 12 || digits.length > 1 && digits.startsWith('0')) {
    return digits.split('').map((digit) => units[int.parse(digit)]).join(' ');
  }
  String underThousand(int value) {
    if (value < 20) return units[value];
    if (value < 100) {
      return '${tens[value ~/ 10]}${value % 10 == 0 ? '' : ' ${units[value % 10]}'}';
    }
    return '${units[value ~/ 100]} hundred${value % 100 == 0 ? '' : ' ${underThousand(value % 100)}'}';
  }

  var value = int.parse(digits);
  if (value == 0) return units[0];
  final parts = <String>[];
  for (final scale in [
    (1000000000, 'billion'),
    (1000000, 'million'),
    (1000, 'thousand'),
  ]) {
    if (value >= scale.$1) {
      parts.add('${underThousand(value ~/ scale.$1)} ${scale.$2}');
      value %= scale.$1;
    }
  }
  if (value > 0) parts.add(underThousand(value));
  return parts.join(' ');
}
