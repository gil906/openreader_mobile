import 'package:flutter_test/flutter_test.dart';
import 'package:openreader_native/offline_speech.dart';

void main() {
  test('phone speech pronounces numbers without changing display text', () {
    expect(phoneSpeechInput('123').text, 'one hundred twenty three');
    expect(phoneSpeechInput('0').text, 'zero');
    expect(phoneSpeechInput('12').text, 'twelve');
    expect(phoneSpeechInput('001').text, 'zero zero one');
    expect(
      phoneSpeechInput('999999999999').text,
      'nine hundred ninety nine billion nine hundred ninety nine million nine hundred ninety nine thousand nine hundred ninety nine',
    );
    expect(
      phoneSpeechInput('1234567890123456').text,
      'one two three four five six seven eight nine zero one two three four five six',
    );
    expect(phoneSpeechInput('-12').text, 'minus twelve');
  });
  test(
    'technical and invisible characters cannot produce an empty number passage',
    () {
      expect(
        phoneSpeechInput('192.0.2.10').text,
        'one hundred ninety two dot zero dot two dot ten',
      );
      expect(
        phoneSpeechInput('Port 443 / IPv6').text,
        'Port four hundred forty three slash IPv six',
      );
      expect(phoneSpeechInput('3.05').text, 'three point zero five');
      expect(
        phoneSpeechInput('\u200b１２３\u2060').text,
        'one hundred twenty three',
      );
      expect(
        phoneSpeechInput('A → B ≥ 0').text,
        'A right arrow B greater than or equal to zero',
      );
      expect(phoneSpeechInput('office ﬁle').text, 'office file');
    },
  );
  test('only non-spoken formatting is explicitly marked as a short pause', () {
    for (final separator in ['', ' ', '•', '——', '---', '...', '()']) {
      expect(phoneSpeechInput(separator).separator, isTrue);
    }
    for (final readable in ['123', 'OSPF', '/', '=', '✓', 'hello']) {
      expect(phoneSpeechInput(readable).separator, isFalse);
      expect(phoneSpeechInput(readable).text, isNotEmpty);
    }
  });
}
