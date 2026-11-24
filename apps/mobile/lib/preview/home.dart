import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/content.dart';
import '../ui/controls.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';

final _tab = NotifierProvider<_TabSelection, CommunityTab>(_TabSelection.new);

class _TabSelection extends Notifier<CommunityTab> {
  @override
  CommunityTab build() => CommunityTab.feed;
  void select(CommunityTab tab) => state = tab;
}

class PreviewHome extends ConsumerWidget {
  const PreviewHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(_tab);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            PageHeader(
              selected.label,
              subtitle: '開発プレビュー',
              action: switch (selected) {
                CommunityTab.feed || CommunityTab.content => IconAction(
                  Icons.search,
                  '検索',
                  onPressed: () => context.push('/search'),
                ),
                CommunityTab.notifications => IconAction(
                  Icons.tune,
                  '通知設定',
                  onPressed: () => context.push('/settings'),
                ),
                _ => null,
              },
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: Space.maxContent),
                  child: switch (selected) {
                    CommunityTab.feed => const _Feed(),
                    CommunityTab.content => const _Hub(),
                    CommunityTab.notifications => const _Notifications(),
                    CommunityTab.profile => const _Profile(),
                    CommunityTab.more => const _More(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: selected == CommunityTab.feed
          ? ComposeButton(onPressed: () => context.push('/compose'))
          : null,
      bottomNavigationBar: CommunityBar(
        selected: selected,
        unread: 2,
        onSelect: ref.read(_tab.notifier).select,
      ),
    );
  }
}

const _posts = [
  FeedPost(
    author: 'プレビュー編集部',
    time: 'きょう 09:00',
    official: true,
    pinned: true,
    body: '音声とギャラリーのサンプルを追加しました。コンテンツからご覧いただけます。',
    tags: ['お知らせ'],
    likes: 24,
    comments: 3,
    liked: true,
  ),
  FeedPost(
    author: 'ながれ雲',
    time: 'きょう 08:24',
    body: '朝の散歩で、遠くの丘に日が差していました。空の色が変わっていくのを見ていたら、いつもの道も少し違って見えました。',
    tags: ['朝の散歩', 'きょうの空', '季節の便り', '小さな発見'],
    photos: [Landscape(CoverScene.morning)],
    likes: 12,
    comments: 4,
  ),
  FeedPost(
    author: '木のしおり',
    time: 'きのう 18:40',
    body: '夕暮れの色を二枚にまとめました。みなさんは、どちらの景色が好きですか？',
    tags: ['夕暮れ', '風景'],
    photos: [Landscape(CoverScene.evening), Landscape(CoverScene.coast)],
    likes: 8,
    comments: 2,
  ),
  FeedPost(author: '水色ノート', time: 'きのう 17:10', body: 'きょうもおつかれさまです。'),
];

class _Feed extends StatefulWidget {
  const _Feed();

  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  FeedCategory _category = FeedCategory.all;
  final _changedLikes = <FeedPost>{};

  bool _liked(FeedPost post) => post.liked != _changedLikes.contains(post);

  @override
  Widget build(BuildContext context) {
    final posts = switch (_category) {
      FeedCategory.all => _posts,
      FeedCategory.artist => const <FeedPost>[],
      FeedCategory.official => _posts.where((post) => post.official).toList(),
      FeedCategory.favorites => _posts.where(_liked).toList(),
      FeedCategory.tags =>
        _posts.where((post) => post.tags.isNotEmpty).toList(),
    };
    return Column(
      children: [
        CategoryStrip(
          selected: _category,
          onSelect: (category) => setState(() => _category = category),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              if (mounted) showNotice(context, '一覧を更新しました。');
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(
                bottom: Space.navigation + Space.edge,
              ),
              itemCount: posts.isEmpty ? 1 : posts.length,
              itemBuilder: (context, index) {
                if (posts.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.edge),
                    child: StateNotice(ViewState.empty),
                  );
                }
                final post = posts[index];
                final liked = _liked(post);
                return PostCard(
                  FeedPost(
                    author: post.author,
                    time: post.time,
                    body: post.body,
                    official: post.official,
                    pinned: post.pinned,
                    tags: post.tags,
                    photos: post.photos,
                    liked: liked,
                    likes:
                        post.likes +
                        (liked == post.liked
                            ? 0
                            : liked
                            ? 1
                            : -1),
                    comments: post.comments,
                  ),
                  onLike: () => setState(() {
                    if (!_changedLikes.add(post)) _changedLikes.remove(post);
                  }),
                  onComment: () => showNotice(context, 'コメント欄の表示は今後追加します。'),
                  onShare: () => showNotice(context, 'プレビュー内の投稿です。'),
                  onMore: () => _postOptions(context),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _postOptions(BuildContext context) =>
      showActions(context, '投稿の操作', [
        const SettingsRow(
          '投稿を保存',
          icon: Icons.bookmark_border,
          subtitle: 'プレビュー',
        ),
        Builder(
          builder: (sheetContext) => SettingsRow(
            '報告する',
            icon: Icons.flag_outlined,
            onTap: () async {
              Navigator.pop(sheetContext);
              if (!context.mounted) return;
              final confirmed = await confirmAction(
                context,
                title: '投稿を報告しますか？',
                message: 'この操作はプレビュー用です。',
                action: '報告する',
                destructive: true,
              );
              if (confirmed && context.mounted) {
                showNotice(context, 'プレビューの操作を確認しました。');
              }
            },
          ),
        ),
      ]);
}

class _Hub extends StatefulWidget {
  const _Hub();

  @override
  State<_Hub> createState() => _HubState();
}

class _HubState extends State<_Hub> {
  static const _featured = [
    ('朝のさんぽ便り', '丘を歩きながら聞く、短い音声サンプル。', CoverScene.morning),
    ('夕暮れの色', '一日の終わりを描いたイラスト集。', CoverScene.evening),
  ];
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final (title, summary, scene) = _featured[_index];
    return ListView(
      padding: const EdgeInsets.all(Space.edge),
      children: [
        Material(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(Space.radius),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                button: true,
                label: title,
                child: InkWell(
                  onTap: () =>
                      context.push(_index == 0 ? '/player' : '/gallery'),
                  child: CoverArt(scene, ratio: 2.2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: Space.edge,
                  top: Space.sm,
                  right: Space.xs,
                  bottom: Space.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: TypeStyles.heading),
                          Text(summary),
                        ],
                      ),
                    ),
                    IconAction(
                      Icons.navigate_next,
                      '次のおすすめ',
                      onPressed: () => setState(
                        () => _index = (_index + 1) % _featured.length,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.gap),
        BannerDots(index: _index, count: _featured.length),
        const SizedBox(height: Space.xl),
        const SectionTitle('コンテンツを探す'),
        AdaptiveTiles(
          children: [
            ContentTile(
              'VOICE',
              Icons.headphones,
              detail: '音声を聴く',
              onPressed: () => context.push('/voice'),
            ),
            ContentTile(
              'GALLERY',
              Icons.photo_library_outlined,
              detail: 'アルバムを見る',
              onPressed: () => context.push('/gallery'),
            ),
            ContentTile(
              '今日のヒトコト',
              Icons.wb_sunny_outlined,
              detail: '短いお便り',
              onPressed: () => context.push('/voice'),
            ),
            ContentTile(
              'コレクション',
              Icons.bookmarks_outlined,
              detail: '保存した作品',
              onPressed: () => context.push('/gallery'),
            ),
          ],
        ),
        const SizedBox(height: Space.xl),
        const SectionTitle('最近見たコンテンツ'),
        SettingsRow(
          '夕暮れの色',
          icon: Icons.history,
          subtitle: 'ギャラリー',
          onTap: () => context.push('/gallery'),
        ),
        SettingsRow(
          '朝のさんぽ便り',
          icon: Icons.history,
          subtitle: '音声 · 3:48',
          onTap: () => context.push('/player'),
        ),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.gap),
    child: Semantics(
      header: true,
      child: Text(label, style: TypeStyles.heading),
    ),
  );
}

/// Variable tile height keeps Japanese labels and scaled text legible.
class AdaptiveTiles extends StatelessWidget {
  const AdaptiveTiles({super.key, required this.children, this.hub = true});
  final List<Widget> children;
  final bool hub;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(15) > 23;
      final columns = constraints.maxWidth >= 580 && hub && !largeText
          ? 3
          : constraints.maxWidth < 360 && largeText
          ? 1
          : 2;
      final width =
          (constraints.maxWidth - (columns - 1) * Space.gap) / columns;
      return Wrap(
        spacing: Space.gap,
        runSpacing: Space.gap,
        children: [
          for (final item in children) SizedBox(width: width, child: item),
        ],
      );
    },
  );
}

class _Notifications extends StatefulWidget {
  const _Notifications();
  @override
  State<_Notifications> createState() => _NotificationsState();
}

class _NotificationsState extends State<_Notifications> {
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    const notices = [
      ('投稿にいいねが付きました', 'きょう 09:10', Icons.favorite_border, true),
      ('音声サンプルが公開されました', 'きょう 09:00', Icons.headphones, true),
      ('ギャラリーが更新されました', 'きのう 18:40', Icons.photo_library_outlined, false),
    ];
    final filtered = _filter == 0
        ? notices
        : notices.where((item) => item.$4).toList();
    return Column(
      children: [
        SectionTabs(
          const ['すべて', '未読'],
          selected: _filter,
          onSelect: (index) => setState(() => _filter = index),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final (title, time, icon, unread) = filtered[index];
              return SettingsRow(
                title,
                icon: icon,
                subtitle: unread ? '未読 · $time' : '既読 · $time',
                onTap: () => showNotice(context, '通知のサンプルです。'),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(Space.edge),
    children: [
      const Row(
        children: [
          AvatarMark(size: 54),
          SizedBox(width: Space.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('プレビュー会員', style: TypeStyles.heading),
                Text('空の色や散歩の記録が好きです。'),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: Space.xl),
      Container(
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(
          color: Palette.warm,
          borderRadius: BorderRadius.circular(Space.radius),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.badge_outlined, color: Palette.warning, size: 30),
            SizedBox(height: Space.sm),
            Text('会員証プレビュー', style: TypeStyles.heading),
            Text('表示サンプル · DEMO'),
          ],
        ),
      ),
      const SizedBox(height: Space.xl),
      const SectionTitle('プロフィール'),
      SettingsRow(
        'お気に入り',
        icon: Icons.star_border,
        onTap: () => context.push('/gallery'),
      ),
      SettingsRow(
        '最近のアクティビティ',
        icon: Icons.history,
        onTap: () => context.push('/voice'),
      ),
      SettingsRow(
        '通知設定',
        icon: Icons.notifications_none,
        onTap: () => context.push('/settings'),
      ),
    ],
  );
}

class _More extends StatelessWidget {
  const _More();

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      SettingsRow(
        '通知・表示設定',
        icon: Icons.tune,
        onTap: () => context.push('/settings'),
      ),
      SettingsRow(
        'コンポーネントと画面状態',
        icon: Icons.dashboard_outlined,
        onTap: () => context.push('/states'),
      ),
      const SettingsRow(
        'バージョン',
        icon: Icons.info_outline,
        subtitle: '0.1.0 · 開発プレビュー',
      ),
    ],
  );
}
