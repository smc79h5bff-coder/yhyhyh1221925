import 'package:docdiff/features/parser/application/parse_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ParseLimits', () {
    test('RSS 超过危险线时中止', () {
      final limits = ParseLimits(
        dangerRssBytes: 100,
        rssProbe: () => 200,
        checkInterval: Duration.zero,
      );

      expect(() => limits.checkMemory(), throwsA(isA<ParseAbortException>()));
    });

    test('RSS 低于危险线时放行', () {
      final limits = ParseLimits(
        dangerRssBytes: 100,
        rssProbe: () => 50,
        checkInterval: Duration.zero,
      );

      expect(limits.checkMemory, returnsNormally);
    });

    test('没有 RSS 探测能力时直接放行（web）', () {
      final limits = ParseLimits(
        dangerRssBytes: 100,
        rssProbe: null,
      );

      expect(limits.checkMemory, returnsNormally);
    });

    test('段落数超限时中止', () {
      final limits = ParseLimits(
        dangerRssBytes: 100,
        maxParagraphs: 2,
        rssProbe: null,
      );

      expect(
        () => limits.checkParagraphs(3),
        throwsA(isA<ParseAbortException>()),
      );
    });

    test('章节数超限时中止', () {
      final limits = ParseLimits(
        dangerRssBytes: 100,
        maxChapters: 2,
        rssProbe: null,
      );

      expect(
        () => limits.checkChapters(3),
        throwsA(isA<ParseAbortException>()),
      );
    });

    test('解压上限取危险线一半，且不超过 200MB', () {
      final low = ParseLimits.forDevice(200 * 1024 * 1024);
      expect(low.maxUncompressedBytes, 100 * 1024 * 1024);

      final high = ParseLimits.forDevice(1024 * 1024 * 1024);
      expect(high.maxUncompressedBytes, 200 * 1024 * 1024);
    });
  });
}
