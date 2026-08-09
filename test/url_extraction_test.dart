import 'package:flutter_test/flutter_test.dart';
import 'package:friends_vault/ui/home_screen.dart';

void main() {
  test('extractUrl captures normal https links', () {
    final text = '请看这个链接 https://example.com/page?abc=1';
    expect(extractUrl(text), 'https://example.com/page?abc=1');
  });

  test('extractUrl strips trailing punctuation', () {
    final text = '看看这个 https://example.com/page, 好的';
    expect(extractUrl(text), 'https://example.com/page');
  });

  test('extractUrl returns null for plain text without URL', () {
    expect(extractUrl('这不是网址'), isNull);
  });
}
