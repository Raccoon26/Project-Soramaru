import 'package:bootstrap/navigation/deep_links.dart';
import 'package:bootstrap/navigation/destinations.dart';
import 'package:bootstrap/navigation/ja.dart';
import 'package:bootstrap/navigation/sample_data.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'all screen IDs, titles and paths are unique and shell tabs are ordered',
    () {
      expect(
        Screen.values.map((screen) => screen.id).toSet(),
        hasLength(Screen.values.length),
      );
      expect(
        Screen.values.map((screen) => screen.pattern).toSet(),
        hasLength(Screen.values.length),
      );
      expect(screenTitles.keys.toSet(), Screen.values.toSet());
      expect(Screen.tabs.map(Ja.title), [
        'ファン投稿',
        'コンテンツ',
        '通知',
        'マイページ',
        'その他',
      ]);
      expect(Screen.values.any((screen) => screen.id.startsWith('O')), isFalse);
      for (final screen in Screen.values.where(
        (screen) => screen.access == Access.artist,
      )) {
        expect(screen.tab, isNull);
        expect(screen.linkKind, isNull);
      }
    },
  );

  const parser = DeepLinks(SampleResources());
  test('all nine permitted categories normalize to typed destinations', () {
    const cases = {
      'post/post-1': '/feed/posts/post-1',
      'comment/comment-1': '/feed/posts/post-1/comments',
      'notice/notice-1': '/content/notices/notice-1',
      'voice/voice-1': '/content/voice/tracks/voice-1',
      'album/album-1': '/content/gallery/album-1',
      'personal/personal-1': '/notifications/personal/personal-1',
      'badge/badge-1': '/profile/badges/badge-1',
      'card/card-1': '/profile/cards/card-1',
      'profile/user-1': '/profile/users/user-1',
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(parser.parse('soramaru-dev://open/$key')?.location, value);
    }
  });

  test('malformed, encoded, oversized and disallowed inputs fail closed', () {
    for (final value in [
      'https://example.invalid/post/post-1',
      '/feed/posts/post-1',
      'soramaru-dev://other/post/post-1',
      'soramaru-dev://open:443/post/post-1',
      'soramaru-dev://user@open/post/post-1',
      'soramaru-dev://open/post/post-1?id=post-1&id=post-2',
      'soramaru-dev://open/post/post-1?url=https://example.invalid',
      'soramaru-dev://open/post/post-1#tail',
      'soramaru-dev://open/post/%2fadmin',
      'soramaru-dev://open/post/..',
      'soramaru-dev://open/post/post-1\n',
      'soramaru-dev://open/post/post-1/anything',
      'soramaru-dev://open/artist/post-1',
      'soramaru-dev://open/compose/post-1',
      'soramaru-dev://open/post/${'x' * 130}',
    ]) {
      expect(parser.parse(value), isNull, reason: value);
    }
  });

  test('pending links expire and cannot cross a generation', () {
    final now = DateTime.utc(2026, 11, 24);
    final pending = PendingDestination(
      const Destination(Screen.post, 'post-1'),
      0,
      now.add(const Duration(minutes: 5)),
    );
    expect(pending.valid(0, now), isTrue);
    expect(pending.valid(1, now), isFalse);
    expect(pending.valid(0, pending.expires), isFalse);
  });

  test(
    'statuses distinguish authenticated, blocked and sign-in transitions',
    () {
      for (final status in SessionStatus.values) {
        final session = DemoSession(status: status);
        expect(session.signedIn, status == SessionStatus.member);
        expect(
          session.canSignIn,
          status == SessionStatus.signedOut || status == SessionStatus.expired,
        );
        expect(session.explanation, isNotEmpty);
      }
    },
  );

  test('localized dates and counts from UTC follow Japan Standard Time', () {
    final utc = DateTime.utc(2026, 11, 24, 15, 4);
    expect(Ja.date(utc), '2026年11月25日');
    expect(Ja.time(utc), '00:04');
    expect(Ja.pieces(12345), '12,345件');
    expect(Ja.relative(utc, utc.add(const Duration(minutes: 22))), '22分前');
    expect(Ja.relative(utc, utc.add(const Duration(hours: 3))), '3時間前');
  });
}
