import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'destinations.dart';

enum ResourceStatus { found, missing, deleted, forbidden }

abstract interface class NavigationResources {
  ResourceStatus statusOf(Screen screen, String id);
  String? postForComment(String comment);
}

final navigationResourcesProvider = Provider<NavigationResources>(
  (ref) => const SampleResources(),
);

class SampleResources implements NavigationResources {
  const SampleResources();

  @override
  String? postForComment(String comment) => switch (comment) {
    'comment-1' => 'post-1',
    'deleted' || 'private' || 'missing' => comment,
    _ => null,
  };

  @override
  ResourceStatus statusOf(Screen screen, String id) {
    final owner =
        screen.linkKind != null ||
            screen.parent == null ||
            !screen.parent!.hasResource
        ? screen
        : screen.parent!;
    if (id == 'deleted') return ResourceStatus.deleted;
    if (id == 'private') return ResourceStatus.forbidden;
    final entries = switch (owner) {
      Screen.post ||
      Screen.comments => const ['post-1', 'post-2', 'post-3', 'post-4'],
      Screen.voiceDetail => const ['voice-1', 'voice-2'],
      Screen.album => const ['album-1', 'album-2'],
      Screen.notice => const ['notice-1'],
      Screen.personal => const ['personal-1'],
      Screen.badge => const ['badge-1'],
      Screen.card => const ['card-1'],
      Screen.user => const ['user-1'],
      Screen.tagged => const ['sky', 'walk'],
      Screen.folder => const ['folder-1'],
      Screen.device => const ['device-1'],
      _ => const <String>[],
    };
    return entries.contains(id) ? ResourceStatus.found : ResourceStatus.missing;
  }
}

class MockNotice {
  const MockNotice(this.title, this.target, {this.unread = false});
  final String title;
  final Destination target;
  final bool unread;
}

const sampleNotices = [
  MockNotice(
    '投稿にコメントが届きました',
    Destination(Screen.comments, 'post-1'),
    unread: true,
  ),
  MockNotice(
    'コメントに返信が届きました',
    Destination(Screen.comments, 'post-2'),
    unread: true,
  ),
  MockNotice('投稿にいいねが付きました', Destination(Screen.post, 'post-2')),
  MockNotice('公式のお知らせが届きました', Destination(Screen.notice, 'notice-1')),
  MockNotice('新しい音声サンプルが届きました', Destination(Screen.voiceDetail, 'voice-1')),
  MockNotice('バッジを獲得しました', Destination(Screen.badge, 'badge-1')),
  MockNotice('メッセージカードが届きました', Destination(Screen.card, 'card-1')),
  MockNotice('あなたへのお知らせが届きました', Destination(Screen.personal, 'personal-1')),
];
