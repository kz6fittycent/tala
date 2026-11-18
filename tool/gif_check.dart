// Runs Tala's real GIF calls against a throwaway Nextcloud with the Giphy
// app (integration_giphy) installed. Read-only, but never point it at a real
// account.
//
//   TALA_GIF_CHECK_URL=http://127.0.0.1:8089 TALA_GIF_CHECK_USER=alice \
//   TALA_GIF_CHECK_PASSWORD=... flutter test tool/gif_check.dart
//
// Without a Giphy key on the server it checks what Tala does then; with one
// (`occ config:app:set integration_giphy api_key --value=... --sensitive`)
// it also searches and plays a sent link. Pictures come through the server
// either way. It refuses anything but http://127.0.0.1.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tala/src/chat.dart' show ApiException;
import 'package:tala/src/giphy.dart';
import 'package:tala/src/nc_api.dart';

/// The 200-wide version of a long-lived Giphy picture.
const _known =
    '/index.php/apps/integration_giphy/gif/direct/BaDsH4FpMBnqdK8J0g/'
    'media4/200w.gif/cid/200w.gif/g';
const _knownLink = 'https://giphy.com/gifs/seal-sappy-seals-BaDsH4FpMBnqdK8J0g';

bool _isWebp(List<int> b) =>
    b.length > 12 &&
    String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
    String.fromCharCodes(b.sublist(8, 12)) == 'WEBP';

void main() {
  final env = Platform.environment;
  final url = env['TALA_GIF_CHECK_URL'] ?? '';
  final skip = url.startsWith('http://127.0.0.1')
      ? null
      : 'set TALA_GIF_CHECK_URL to a local throwaway server';
  NcApi api() => NcApi(Credentials(
        url,
        env['TALA_GIF_CHECK_USER'] ?? '',
        env['TALA_GIF_CHECK_PASSWORD'] ?? '',
      ));

  test('GIFs through the server', () async {
    final a = api();
    final support = await a.gifSupport();
    expect(support, isNot(GifSupport.none));

    // Pictures pass through the server whether or not it has a key, and the
    // WebP copy is what arrives.
    final bytes = await a.gifMedia(_known);
    expect(_isWebp(bytes), isTrue);
    expect(bytes.length, lessThan(1024 * 1024));

    if (support == GifSupport.unconfigured) {
      await expectLater(
        a.searchGifs('cat', 0),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
      expect(await a.gifForLink(_knownLink), isNull);
      // ignore: avoid_print
      print('gif_check: no Giphy key on the server; searching not checked');
      return;
    }

    final trending = await a.searchGifs('', 0);
    expect(trending.gifs, isNotEmpty);
    final page = await a.searchGifs('cat', 0);
    expect(page.gifs.length, GifPage.size);
    expect(page.more, isTrue);
    final next = await a.searchGifs('cat', page.next);
    expect(next.gifs.first.link, isNot(page.gifs.first.link));
    expect(page.gifs.first.link, predicate<String>(isGiphyLink));
    expect((await a.gifMedia(page.gifs.first.mediaPath)).length, greaterThan(0));

    final linked = await a.gifForLink(page.gifs.first.link);
    expect(linked, isNotNull);
    expect(_isWebp(linked!), isTrue);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
