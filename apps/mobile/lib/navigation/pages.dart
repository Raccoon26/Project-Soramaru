import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../membership/controller.dart';
import '../membership/screens.dart';
import '../network/api_notice.dart';
import '../preview/home.dart'
    show AdaptiveTiles, FeedPreview, SectionTitle, sampleFeedPosts;
import '../preview/pages.dart' show ComposePreview, PlayerPreview, StateCatalog;
import '../ui/content.dart';
import '../ui/controls.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import 'destinations.dart';
import 'ja.dart';
import 'navigation_app.dart';
import 'sample_data.dart';
import 'session.dart';

class NavigationPage extends StatelessWidget {
  const NavigationPage({
    super.key,
    required this.navigation,
    required this.screen,
    this.resource,
  });
  final NavigationController navigation;
  final Screen screen;
  final String? resource;

  @override
  Widget build(BuildContext context) {
    final n = navigation;
    final id = resource;
    return switch (screen) {
      Screen.compose => ComposePreview(
        onExit: n.back,
        choosePhoto: () =>
            n.open<CoverScene>(const Destination(Screen.pickPhoto)),
        chooseTag: () => n.open<String>(const Destination(Screen.pickTag)),
        initialDraft: n.draft,
        onSaveDraft: (value) => n.draft = value,
      ),
      Screen.player => PlayerPreview(
        initialTrack: id == 'voice-2' ? 1 : 0,
        onBack: n.back,
      ),
      Screen.catalog => const StateCatalog(),
      Screen.login ||
      Screen.restricted ||
      Screen.unavailable ||
      Screen.invalidLink => BoundaryPage(navigation: n, screen: screen),
      _ => _ScreenFrame(
        screen: screen,
        navigation: n,
        child: _content(context),
      ),
    };
  }

  Widget _content(BuildContext context) {
    final n = navigation;
    final id = resource;
    final membership = n.realMembership;
    void open(Screen screen, [String? resource]) =>
        n.open<void>(Destination(screen, resource));
    switch (screen) {
      case Screen.feed:
        if (membership != null) {
          return _list([const StateNotice(ViewState.empty)]);
        }
        return FeedPreview(
          restorable: n.restorationId != null,
          controller: n.scrollFor(CommunityTab.feed),
          onPost: (index) => open(Screen.post, 'post-$index'),
          onComments: (index) => open(Screen.comments, 'post-$index'),
          onTags: () => open(Screen.tags),
        );
      case Screen.post:
        final post = sampleFeedPosts[int.parse(id!.split('-').last) - 1];
        return _list([
          PostCard(
            post,
            onComment: () => open(Screen.comments, id),
            onMore: () => showActions(context, '投稿の操作', [
              Builder(
                builder: (sheet) => SettingsRow(
                  'コメントを見る',
                  icon: Icons.chat_bubble_outline,
                  onTap: () {
                    Navigator.pop(sheet);
                    open(Screen.comments, id);
                  },
                ),
              ),
            ]),
          ),
          _row(Screen.comments, id: id, icon: Icons.chat_bubble_outline),
        ]);
      case Screen.comments:
        return _list([
          const SettingsRow(
            '水色ノート',
            subtitle: 'すてきな風景ですね。',
            icon: Icons.chat_bubble_outline,
          ),
          const SettingsRow(
            '木のしおり',
            subtitle: 'ありがとうございます。',
            icon: Icons.reply,
          ),
          ActionButton(
            'スタンプを見る',
            kind: ButtonKind.secondary,
            onPressed: () => showActions(context, 'スタンプ', [
              const SettingsRow(
                '拍手',
                subtitle: Ja.demoOnly,
                icon: Icons.emoji_emotions_outlined,
              ),
            ]),
          ),
        ]);
      case Screen.search:
        return _SearchPage(navigation: n);
      case Screen.pickTag:
        return _list([
          SettingsRow(
            '朝の散歩',
            icon: Icons.tag,
            onTap: () => n.back<String>('朝の散歩'),
          ),
          SettingsRow(
            '季節の便り',
            icon: Icons.tag,
            onTap: () => n.back<String>('季節の便り'),
          ),
        ]);
      case Screen.pickPhoto:
        return _list([
          const Text('写真へのアクセスは行いません。サンプルを選んでください。'),
          const SizedBox(height: Space.gap),
          AdaptiveTiles(
            hub: false,
            children: [
              MediaCard(
                title: '朝の風景',
                detail: Ja.demoOnly,
                cover: const Landscape(CoverScene.morning),
                onPressed: () => n.back<CoverScene>(CoverScene.morning),
              ),
              MediaCard(
                title: '海辺の風景',
                detail: Ja.demoOnly,
                cover: const Landscape(CoverScene.coast),
                onPressed: () => n.back<CoverScene>(CoverScene.coast),
              ),
            ],
          ),
        ]);
      case Screen.tags:
        return _list([
          SettingsRow(
            '#きょうの空',
            icon: Icons.tag,
            onTap: () => open(Screen.tagged, 'sky'),
          ),
          SettingsRow(
            '#朝の散歩',
            icon: Icons.tag,
            onTap: () => open(Screen.tagged, 'walk'),
          ),
        ]);
      case Screen.tagged:
        return _list([
          SectionTitle(id == 'sky' ? '#きょうの空' : '#朝の散歩'),
          PostCard(
            sampleFeedPosts[1],
            onOpen: () => open(Screen.post, 'post-2'),
          ),
        ]);
      case Screen.content:
        return _list([
          const CoverArt(CoverScene.morning, ratio: 2.2),
          const SizedBox(height: Space.gap),
          const SectionTitle('コンテンツを探す'),
          AdaptiveTiles(
            children: [
              _tile(Screen.voice, Icons.headphones, detail: '音声のサンプル'),
              _tile(
                Screen.gallery,
                Icons.photo_library_outlined,
                detail: '風景のイラスト',
              ),
              _tile(Screen.today, Icons.wb_sunny_outlined),
              _tile(Screen.notices, Icons.campaign_outlined),
            ],
          ),
          const SizedBox(height: Space.xl),
          _row(Screen.recent, icon: Icons.history),
          _row(
            Screen.goods,
            icon: Icons.confirmation_number_outlined,
            subtitle: Ja.demoOnly,
          ),
        ]);
      case Screen.today:
        return _list([
          const SectionTitle('朝のさんぽ便り'),
          const Text('庭に咲いた花を見つけました。よい一日になりますように。'),
          _row(Screen.voiceDetail, id: 'voice-1', icon: Icons.headphones),
        ]);
      case Screen.voice:
        return _MediaShelf(navigation: n);
      case Screen.gallery:
        return _MediaShelf(navigation: n, albums: true);
      case Screen.voiceDetail:
        return _list([
          const CoverArt(CoverScene.morning),
          const SizedBox(height: Space.gap),
          SectionTitle(id == 'voice-2' ? '波の聞こえる場所' : '朝のさんぽ便り'),
          const Text('音声サンプル · 3:48'),
          const SizedBox(height: Space.gap),
          ActionButton(
            'プレーヤーを開く',
            icon: Icons.play_arrow,
            onPressed: () => open(Screen.player, id),
          ),
        ]);
      case Screen.playlist || Screen.downloads:
        return _list([
          const Text(Ja.demoOnly),
          _row(
            Screen.voiceDetail,
            id: 'voice-1',
            icon: Icons.headphones,
            subtitle: '朝のさんぽ便り',
          ),
        ]);
      case Screen.album:
        return _list([
          const SectionTitle('風景イラスト'),
          MediaCard(
            title: '写真ビューアを開く',
            detail: 'イラスト · 2枚',
            cover: const Landscape(CoverScene.evening),
            album: true,
            onPressed: () => open(Screen.photo, id),
          ),
        ]);
      case Screen.photo:
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(Space.edge),
              child: InteractiveViewer(
                child: Semantics(
                  image: true,
                  label: '夕暮れの風景イラスト',
                  child: const CoverArt(CoverScene.evening, ratio: 4 / 3),
                ),
              ),
            ),
          ),
        );
      case Screen.recent:
        return _list([
          _row(
            Screen.voiceDetail,
            id: 'voice-1',
            icon: Icons.headphones,
            subtitle: '朝のさんぽ便り',
          ),
          _row(
            Screen.album,
            id: 'album-1',
            icon: Icons.image_outlined,
            subtitle: '夕暮れの色',
          ),
          _row(Screen.notice, id: 'notice-1', icon: Icons.campaign_outlined),
        ]);
      case Screen.notices:
        return _list([
          _row(
            Screen.notice,
            id: 'notice-1',
            icon: Icons.campaign_outlined,
            subtitle: 'プレビューのお知らせ',
          ),
        ]);
      case Screen.notice:
        return _list([
          const SectionTitle('プレビューのお知らせ'),
          const Text('新しいイラストと音声サンプルをご覧いただけます。'),
          _row(Screen.voiceDetail, id: 'voice-1', icon: Icons.headphones),
        ]);
      case Screen.goods:
        return _list([const Text('ご案内できるリンクはありません。')]);
      case Screen.notifications:
        return _NotificationList(navigation: n);
      case Screen.personal:
        return _list([const Text('この画面は個人向けお知らせの表示サンプルです。')]);
      case Screen.profile:
        if (membership != null) {
          return ListenableBuilder(
            listenable: membership,
            builder: (context, _) {
              final profile = membership.profile;
              if (profile == null) return const StateNotice(ViewState.loading);
              final joined = DateTime.fromMillisecondsSinceEpoch(
                profile['joinedAt'] as int,
                isUtc: true,
              );
              final days = DateTime.now()
                  .difference(joined)
                  .inDays
                  .clamp(0, 365000);
              return _list([
                const AvatarMark(size: 50),
                Text(profile['nickname'] as String, style: TypeStyles.heading),
                Text(profile['biography'] as String),
                Text("会員番号　${profile['memberNumber']}"),
                Text('入会日　${Ja.date(joined)}'),
                Text('会員期間　$days日'),
                _row(Screen.editProfile),
                _row(Screen.devices),
              ]);
            },
          );
        }
        return _list([
          ValueListenableBuilder<String>(
            valueListenable: n.profileName,
            builder: (context, name, _) => ValueListenableBuilder<bool>(
              valueListenable: n.badgeApplied,
              builder: (context, applied, _) => Row(
                children: [
                  AvatarMark(size: 50, badge: applied),
                  const SizedBox(width: Space.gap),
                  Expanded(child: Text(name, style: TypeStyles.heading)),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.xl),
          _tile(
            Screen.membership,
            Icons.badge_outlined,
            detail: '表示サンプル · DEMO',
          ),
          const SizedBox(height: Space.edge),
          for (final page in [
            Screen.editProfile,
            Screen.badges,
            Screen.cards,
            Screen.activity,
            Screen.favorites,
            Screen.collections,
            Screen.devices,
            Screen.blocks,
          ])
            _row(page),
        ]);
      case Screen.editProfile:
        if (membership != null) {
          return _list([MemberEditor(membership, onSaved: n.back)]);
        }
        return _ProfileEditor(navigation: n);
      case Screen.membership:
        return OrientationBuilder(
          builder: (context, orientation) => _list([
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: orientation == Orientation.landscape
                    ? Space.section
                    : 0,
              ),
              child: ContentTile(
                '会員証プレビュー',
                Icons.badge_outlined,
                detail: '表示サンプル · DEMO',
                onPressed: n.back,
              ),
            ),
          ]),
        );
      case Screen.badges:
        return _list([
          _row(
            Screen.badge,
            id: 'badge-1',
            icon: Icons.workspace_premium_outlined,
            subtitle: '朝のさんぽ',
          ),
        ]);
      case Screen.badge:
        return _list([
          const AvatarMark(badge: true),
          const SizedBox(height: Space.gap),
          const Text('朝のさんぽ'),
          ValueListenableBuilder<bool>(
            valueListenable: n.badgeApplied,
            builder: (context, applied, _) => ActionButton(
              applied ? '適用を外す' : 'バッジを試す',
              onPressed: () => n.badgeApplied.value = !applied,
            ),
          ),
        ]);
      case Screen.cards:
        return _list([
          _row(Screen.card, id: 'card-1', icon: Icons.mail_outline),
        ]);
      case Screen.card:
        return _list([
          const CoverArt(CoverScene.garden),
          const Text('いつもおつかれさま。ゆっくり休んでくださいね。'),
        ]);
      case Screen.activity:
        return _list([
          _row(
            Screen.post,
            id: 'post-2',
            icon: Icons.chat_bubble_outline,
            subtitle: '散歩の記録',
          ),
        ]);
      case Screen.favorites:
        return _list([
          SettingsRow(
            'ユーザー',
            icon: Icons.person_outline,
            onTap: () => open(Screen.user, 'user-1'),
          ),
          SettingsRow(
            'タグ',
            icon: Icons.tag,
            onTap: () => open(Screen.tagged, 'sky'),
          ),
        ]);
      case Screen.user:
        return _list([
          const SettingsRow(
            'ながれ雲',
            subtitle: Ja.demoOnly,
            icon: Icons.person_outline,
          ),
        ]);
      case Screen.collections:
        return _list([
          _row(
            Screen.folder,
            id: 'folder-1',
            icon: Icons.folder_outlined,
            subtitle: '空の風景',
          ),
        ]);
      case Screen.folder:
        return _list([
          _row(
            Screen.album,
            id: 'album-1',
            icon: Icons.image_outlined,
            subtitle: '夕暮れの色',
          ),
        ]);
      case Screen.devices:
        if (membership != null) {
          return _list([
            DevicesPane(
              membership,
              open: (alias) => open(Screen.device, alias),
            ),
          ]);
        }
        return _list([
          _row(
            Screen.device,
            id: 'device-1',
            icon: Icons.phone_android,
            subtitle: '端末サンプル',
          ),
        ]);
      case Screen.device:
        if (membership != null) {
          return _list([DevicesPane(membership, open: (_) {}, alias: id)]);
        }
        return _list([const Text('端末サンプルです。識別情報はありません。')]);
      case Screen.blocks:
        return _list([const Text('ブロック中のユーザーはいません。')]);
      case Screen.more:
        return _list([
          const DevApiPanel(),
          for (final page in [
            Screen.notificationSettings,
            Screen.settings,
            Screen.faq,
            Screen.support,
            Screen.terms,
            Screen.privacy,
            Screen.deleteAccount,
            Screen.version,
            Screen.licenses,
            Screen.catalog,
          ])
            _row(page),
          if (membership != null)
            TextButton(
              onPressed: () async {
                if (await confirmSignOut(context, 'ログアウトしますか？')) {
                  await membership.signOut();
                }
              },
              child: const Text('ログアウト'),
            ),
          if (membership == null)
            Consumer(
              builder: (context, ref, _) {
                final session = ref.watch(demoSessionProvider);
                return Column(
                  children: [
                    if (session.role == MemberRole.artist && session.signedIn)
                      for (final page in [
                        Screen.artistPost,
                        Screen.artistSchedule,
                        Screen.artistRewards,
                      ])
                        _row(page),
                    if (session.signedIn)
                      SettingsRow(
                        Ja.demoSignOut,
                        icon: Icons.logout,
                        onTap: () => ref
                            .read(demoSessionProvider.notifier)
                            .change(SessionStatus.signedOut),
                      )
                    else
                      _row(
                        session.canSignIn ? Screen.login : Screen.restricted,
                      ),
                  ],
                );
              },
            ),
        ]);
      case Screen.notificationSettings:
        return const _LocalSetting('お知らせを表示する');
      case Screen.settings:
        return const _LocalSetting('省データ表示');
      case Screen.faq:
        return _list([const Text('よくある質問は準備中です。'), _row(Screen.support)]);
      case Screen.support:
        return _list([const Text('お問い合わせフォームは準備中です。送信はできません。')]);
      case Screen.terms || Screen.privacy:
        if (membership != null) {
          return _list([
            PolicyCopy(
              membership,
              kind: screen == Screen.terms ? 'terms' : 'privacy',
            ),
          ]);
        }
        return _list([const Text('開発用の仮画面です。正式な文書を公開する前の表示サンプルです。')]);
      case Screen.deleteAccount:
        return _list([const Text('アカウント削除の案内は準備中です。この画面からは削除できません。')]);
      case Screen.version:
        return _list([const Text('0.1.0 · 開発プレビュー'), _row(Screen.licenses)]);
      case Screen.licenses:
        return _list([
          ActionButton(
            'ライセンスを表示',
            onPressed: () =>
                showLicensePage(context: context, applicationName: Ja.preview),
          ),
        ]);
      case Screen.artistPost || Screen.artistSchedule || Screen.artistRewards:
        return _list([const Text('公式アカウント向けの開発用画面です。公開操作はできません。')]);
      default:
        return _list([const Text(Ja.empty)]);
    }
  }

  Widget _list(List<Widget> items) => ListView(
    controller: screen == screen.root && screen.tab != null
        ? navigation.scrollFor(screen.tab!)
        : null,
    restorationId: navigation.restorationId == null
        ? null
        : 'list-${screen.id}',
    padding: const EdgeInsets.all(Space.edge),
    children: items,
  );

  Widget _row(
    Screen destination, {
    String? id,
    IconData? icon,
    String? subtitle,
  }) => SettingsRow(
    Ja.title(destination),
    icon: icon,
    subtitle: subtitle,
    onTap: () => navigation.open<void>(Destination(destination, id)),
  );

  Widget _tile(Screen destination, IconData icon, {String? detail}) =>
      ContentTile(
        Ja.title(destination),
        icon,
        detail: detail,
        onPressed: () => navigation.open<void>(Destination(destination)),
      );
}

class _ScreenFrame extends StatelessWidget {
  const _ScreenFrame({
    required this.screen,
    required this.navigation,
    required this.child,
  });
  final Screen screen;
  final NavigationController navigation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final root = Screen.tabs.contains(screen);
    return Scaffold(
      floatingActionButton: screen == Screen.feed
          ? ComposeButton(
              onPressed: () =>
                  navigation.open<void>(const Destination(Screen.compose)),
            )
          : null,
      body: SafeArea(
        bottom: !screen.hasTabBar,
        child: Column(
          children: [
            PageHeader(
              Ja.title(screen),
              subtitle: root ? Ja.preview : null,
              leading: root
                  ? null
                  : IconAction(
                      screen.fullScreen ? Icons.close : Icons.arrow_back,
                      screen.fullScreen ? Ja.close : Ja.back,
                      onPressed: navigation.back,
                    ),
              action: switch (screen) {
                Screen.feed => IconAction(
                  Icons.search,
                  Ja.title(Screen.search),
                  onPressed: () =>
                      navigation.open<void>(const Destination(Screen.search)),
                ),
                Screen.notifications => IconAction(
                  Icons.tune,
                  Ja.title(Screen.notificationSettings),
                  onPressed: () => navigation.open<void>(
                    const Destination(Screen.notificationSettings),
                  ),
                ),
                _ => null,
              },
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: Space.maxContent),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BoundaryPage extends ConsumerWidget {
  const BoundaryPage({
    super.key,
    required this.navigation,
    required this.screen,
  });
  final NavigationController navigation;
  final Screen screen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(membershipProvider);
    if (account != null &&
        (screen == Screen.login || screen == Screen.restricted)) {
      return _ScreenFrame(
        screen: screen,
        navigation: navigation,
        child: MembershipGate(account, onCancel: navigation.cancelSignIn),
      );
    }
    final session = ref.watch(demoSessionProvider);
    final text = switch (screen) {
      Screen.login || Screen.restricted => session.explanation,
      Screen.unavailable => navigation.unavailableReason,
      _ => Ja.badLink,
    };
    return _ScreenFrame(
      screen: screen,
      navigation: navigation,
      child: ListView(
        padding: const EdgeInsets.all(Space.edge),
        children: [
          Semantics(liveRegion: true, child: Text(text)),
          const SizedBox(height: Space.edge),
          if (screen == Screen.login && session.canSignIn)
            ActionButton(
              Ja.demoSignIn,
              onPressed: () {
                ref
                    .read(demoSessionProvider.notifier)
                    .change(SessionStatus.member);
              },
            ),
          ActionButton(
            Ja.back,
            kind: ButtonKind.outline,
            onPressed: navigation.back,
          ),
        ],
      ),
    );
  }
}

class _SearchPage extends StatefulWidget {
  const _SearchPage({required this.navigation});
  final NavigationController navigation;
  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  String _query = '';
  int _filter = 0;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(Space.edge),
    children: [
      InputField(
        Ja.search,
        search: true,
        onChanged: (value) => setState(() => _query = value.trim()),
      ),
      SectionTabs(
        const [Ja.all, '投稿', '音声'],
        selected: _filter,
        onSelect: (value) => setState(() => _filter = value),
      ),
      if (_query.isNotEmpty &&
          _filter != 2 &&
          sampleFeedPosts[1].body.contains(_query))
        SettingsRow(
          '散歩の記録',
          icon: Icons.article_outlined,
          onTap: () => widget.navigation.open<void>(
            const Destination(Screen.post, 'post-2'),
          ),
        )
      else if (_query.isNotEmpty && _filter != 1 && '朝のさんぽ便り'.contains(_query))
        SettingsRow(
          '朝のさんぽ便り',
          icon: Icons.headphones,
          onTap: () => widget.navigation.open<void>(
            const Destination(Screen.voiceDetail, 'voice-1'),
          ),
        )
      else if (_query.isNotEmpty)
        const StateNotice(ViewState.noResults),
    ],
  );
}

class _MediaShelf extends StatefulWidget {
  const _MediaShelf({required this.navigation, this.albums = false});
  final NavigationController navigation;
  final bool albums;
  @override
  State<_MediaShelf> createState() => _MediaShelfState();
}

class _MediaShelfState extends State<_MediaShelf> with RestorationMixin {
  final _filter = RestorableInt(0);
  @override
  String? get restorationId =>
      widget.navigation.restorationId == null ? null : 'media-filter';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) =>
      registerForRestoration(_filter, 'selection');

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final albums = widget.albums;
    final n = widget.navigation;
    final target = albums ? Screen.album : Screen.voiceDetail;
    return Column(
      children: [
        SectionTabs(
          albums ? const [Ja.all, 'コレクション'] : const [Ja.all, 'VOICE', 'RADIO'],
          selected: _filter.value,
          onSelect: (value) => setState(() => _filter.value = value),
        ),
        Expanded(
          child: ListView(
            restorationId: n.restorationId == null ? null : 'media-list',
            padding: const EdgeInsets.all(Space.edge),
            children: [
              AdaptiveTiles(
                hub: false,
                children: [
                  if (_filter.value != 2)
                    MediaCard(
                      title: albums ? '夕暮れの色' : '朝のさんぽ便り',
                      detail: albums ? '2枚' : '3:48',
                      cover: const Landscape(CoverScene.morning),
                      album: albums,
                      collection: albums,
                      onPressed: () => n.open<void>(
                        Destination(target, albums ? 'album-1' : 'voice-1'),
                      ),
                    ),
                  if (_filter.value == 0 || _filter.value == 2)
                    MediaCard(
                      title: albums ? '海辺の風景' : '波の聞こえる場所',
                      detail: albums ? '2枚' : '3:48',
                      cover: const Landscape(CoverScene.coast),
                      album: albums,
                      onPressed: () => n.open<void>(
                        Destination(target, albums ? 'album-2' : 'voice-2'),
                      ),
                    ),
                ],
              ),
              if (!albums) ...[
                const SizedBox(height: Space.gap),
                for (final screen in [Screen.playlist, Screen.downloads])
                  SettingsRow(
                    Ja.title(screen),
                    onTap: () => n.open<void>(Destination(screen)),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _NotificationList extends StatefulWidget {
  const _NotificationList({required this.navigation});
  final NavigationController navigation;
  @override
  State<_NotificationList> createState() => _NotificationListState();
}

class _NotificationListState extends State<_NotificationList>
    with RestorationMixin {
  final _filter = RestorableInt(0);
  @override
  String? get restorationId =>
      widget.navigation.restorationId == null ? null : 'notification-filter';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) =>
      registerForRestoration(_filter, 'selection');

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.navigation;
    final notices = _filter.value == 0
        ? sampleNotices
        : sampleNotices.where((item) => item.unread).toList();
    return Column(
      children: [
        SectionTabs(
          const [Ja.all, Ja.unread],
          selected: _filter.value,
          onSelect: (value) => setState(() => _filter.value = value),
        ),
        Expanded(
          child: ListView.builder(
            controller: n.scrollFor(CommunityTab.notifications),
            restorationId: n.restorationId == null
                ? null
                : 'notifications-list',
            itemCount: notices.length,
            itemBuilder: (context, index) {
              final item = notices[index];
              final time = Ja.time(DateTime.utc(2026, 11, 24, 0, 10 - index));
              return SettingsRow(
                item.title,
                subtitle: '${item.unread ? Ja.unread : Ja.read} · $time',
                icon: Icons.notifications_outlined,
                onTap: () => n.open<void>(item.target),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.navigation});
  final NavigationController navigation;
  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final _name = TextEditingController(
    text: widget.navigation.profileName.value,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(Space.edge),
    children: [
      InputField('表示名', controller: _name, maxLength: 32),
      Wrap(
        spacing: Space.sm,
        children: [
          ActionButton(
            Ja.saveDemo,
            onPressed: () {
              final trimmed = _name.text.trim();
              if (trimmed.isNotEmpty) {
                widget.navigation.profileName.value = trimmed;
              }
              widget.navigation.back();
            },
          ),
          ActionButton(
            Ja.cancel,
            kind: ButtonKind.outline,
            onPressed: widget.navigation.back,
          ),
        ],
      ),
    ],
  );
}

class _LocalSetting extends StatefulWidget {
  const _LocalSetting(this.label);
  final String label;

  @override
  State<_LocalSetting> createState() => _LocalSettingState();
}

class _LocalSettingState extends State<_LocalSetting> {
  bool _enabled = true;
  @override
  Widget build(BuildContext context) => ListView(
    children: [
      SwitchListTile(
        title: Text(widget.label),
        subtitle: const Text(Ja.demoOnly),
        value: _enabled,
        onChanged: (value) => setState(() => _enabled = value),
      ),
    ],
  );
}
