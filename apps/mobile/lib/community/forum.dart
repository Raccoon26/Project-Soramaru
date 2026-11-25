import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../membership/gateway.dart';
import '../navigation/destinations.dart';
import '../navigation/navigation_app.dart';
import '../ui/content.dart';
import '../ui/controls.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import 'community.dart';
import 'drafts.dart';

String whenPosted(Object? value) {
  final time = DateTime.fromMillisecondsSinceEpoch(
    value as int? ?? 0,
    isUtc: true,
  ).add(const Duration(hours: 9));
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${time.year}/${time.month}/${time.day} ${pad(time.hour)}:${pad(time.minute)} JST';
}

Widget forumError(Object error, VoidCallback retry) {
  final failure = error is MembershipFailure
      ? error
      : const MembershipFailure('unavailable');
  return Padding(
    padding: const EdgeInsets.all(Space.edge),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(liveRegion: true, child: Text(failure.message)),
        TextButton(onPressed: retry, child: const Text('再試行')),
      ],
    ),
  );
}

class ForumList extends StatefulWidget {
  const ForumList(
    this.navigation, {
    this.author,
    this.tag,
    this.root = false,
    this.header,
    super.key,
  });
  final NavigationController navigation;
  final String? author, tag;
  final bool root;
  final Widget? header;
  @override
  State<ForumList> createState() => _ForumListState();
}

class _ForumListState extends State<ForumList> with WidgetsBindingObserver {
  late final Community api = widget.navigation.community!;
  late final ScrollController scroll = widget.root
      ? widget.navigation.scrollFor(CommunityTab.feed)
      : ScrollController();
  FeedCategory category = FeedCategory.all;
  final Map<String, Json> posts = {};
  List<Json> pinned = [];
  Object? error;
  String? cursor;
  bool loading = true;
  var sequence = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(_nearEnd);
    api.addListener(_invalidate);
    unawaited(_load(reset: true, clear: true));
  }

  void _invalidate() => unawaited(_load(reset: true, clear: true));
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _invalidate();
  }

  void _nearEnd() {
    if (!loading &&
        error == null &&
        cursor != null &&
        scroll.hasClients &&
        scroll.position.extentAfter < 280) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool reset = false, bool clear = false}) async {
    if (!reset && (loading || cursor == null)) return;
    final generation = ++sequence;
    setState(() {
      loading = true;
      error = null;
      if (reset) cursor = null;
      if (clear) {
        posts.clear();
        pinned = [];
      }
    });
    try {
      final result = category == FeedCategory.tags
          ? await api.read('/v1/tags/popular')
          : await api.read('/v1/posts', {
              'category': category.name,
              'author': ?widget.author,
              'tag': ?widget.tag,
              'cursor': ?cursor,
              'limit': '20',
            });
      if (!mounted || generation != sequence) return;
      setState(() {
        if (reset) {
          posts.clear();
          pinned = [];
        }
        if (result['pinned'] case final List rows) {
          pinned = rows.whereType<Json>().toList();
        }
        for (final row in (result['items'] as List).whereType<Json>()) {
          posts[row['id'] as String] = row;
        }
        // Keep active scrolling bounded. Pull to refresh starts a new window.
        cursor = posts.length >= 600 ? null : result['nextCursor'] as String?;
        loading = false;
      });
    } catch (e) {
      if (!mounted || generation != sequence) return;
      setState(() {
        error = e;
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    api.removeListener(_invalidate);
    scroll.removeListener(_nearEnd);
    if (!widget.root) scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pinIds = pinned.map((row) => row['id']).toSet();
    final rows = [
      ...pinned,
      ...posts.values.where((row) => !pinIds.contains(row['id'])),
    ];
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: rows.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            if (!widget.root) return widget.header ?? const SizedBox.shrink();
            return CategoryStrip(
              selected: category,
              onSelect: (next) {
                if (next == category) return;
                category = next;
                if (scroll.hasClients) scroll.jumpTo(0);
                unawaited(_load(reset: true, clear: true));
              },
            );
          }
          if (index <= rows.length) {
            return ForumCard(
              widget.navigation,
              rows[index - 1],
              key: ValueKey(rows[index - 1]['id']),
            );
          }
          if (loading) {
            return const Padding(
              padding: EdgeInsets.all(Space.edge),
              child: StateNotice(ViewState.loading),
            );
          }
          if (error case final problem?) {
            return forumError(
              problem,
              () => unawaited(_load(reset: cursor == null)),
            );
          }
          if (rows.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(Space.edge),
              child: Text(switch (category) {
                FeedCategory.favorites => 'お気に入りは準備中です。',
                FeedCategory.tags => '人気のタグは準備中です。投稿のタグから一覧を開けます。',
                _ => '表示できる投稿はありません。',
              }),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

class ForumObject extends StatefulWidget {
  const ForumObject(this.navigation, this.id, {this.user = false, super.key});
  final NavigationController navigation;
  final String id;
  final bool user;
  @override
  State<ForumObject> createState() => _ForumObjectState();
}

class _ForumObjectState extends State<ForumObject> with WidgetsBindingObserver {
  late final Community api = widget.navigation.community!;
  late Future<Json> value;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    value = _read();
    api.addListener(_reload);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<Json> _read() =>
      api.read('/v1/${widget.user ? 'members' : 'posts'}/${widget.id}');
  void _reload() {
    if (mounted) setState(() => value = _read());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    api.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: value,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: StateNotice(ViewState.loading));
      }
      if (snapshot.hasError) {
        return Center(child: forumError(snapshot.error!, _reload));
      }
      final row = snapshot.requireData;
      if (widget.user) {
        return ForumList(
          widget.navigation,
          author: widget.id,
          header: Padding(
            padding: const EdgeInsets.all(Space.edge),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row['nickname'] as String, style: TypeStyles.heading),
                Text(row['biography'] as String),
                if (widget.id != api.owner) ...[
                  ActionButton(
                    'ユーザーを報告',
                    onPressed: () =>
                        reportForum(context, api, 'member', widget.id),
                  ),
                  ActionButton(
                    'ブロックする',
                    onPressed: () =>
                        blockForum(context, widget.navigation, widget.id),
                  ),
                ],
                const Text('このユーザーの投稿', style: TypeStyles.heading),
              ],
            ),
          ),
        );
      }
      return ListView(
        children: [ForumCard(widget.navigation, row, detail: true)],
      );
    },
  );
}

void openComposer(NavigationController n, [Draft? draft]) {
  n.composing = draft;
  unawaited(n.open<void>(const Destination(Screen.compose)));
}

class ForumCard extends StatelessWidget {
  const ForumCard(this.navigation, this.post, {this.detail = false, super.key});
  final NavigationController navigation;
  final Json post;
  final bool detail;

  @override
  Widget build(BuildContext context) {
    final n = navigation,
        id = post['id'] as String,
        author = post['authorId'] as String;
    final api = n.community!;
    final quote = post['quote'] as Json?;
    final tags = (post['tags'] as List).whereType<Json>();
    final mine = author == api.owner && post['category'] == 'member';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PostCard(
          FeedPost(
            author: post['nickname'] as String,
            time: whenPosted(post['createdAt']),
            body: post['body'] as String,
            official: post['category'] != 'member',
            pinned: post['pinned'] == true,
          ),
          showReactionCounts: false,
          officialLabel: post['category'] == 'artist' ? 'そらまる' : '公式',
          onAuthor: () => n.open<void>(Destination(Screen.user, author)),
          onOpen: detail
              ? null
              : () => n.open<void>(Destination(Screen.post, id)),
          onShare: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('共有'),
              content: const Text('会員向けの公開リンクは未設定です。外部共有は現在利用できません。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('閉じる'),
                ),
              ],
            ),
          ),
          onMore: () => showActions(context, '投稿の操作', [
            Builder(
              builder: (sheet) => SettingsRow(
                '引用して投稿',
                icon: Icons.format_quote,
                onTap: () {
                  Navigator.pop(sheet);
                  openComposer(n, Draft.fresh(quoteId: id));
                },
              ),
            ),
            if (mine && detail) ...[
              Builder(
                builder: (sheet) => SettingsRow(
                  '投稿を編集',
                  icon: Icons.edit_outlined,
                  onTap: () {
                    Navigator.pop(sheet);
                    final draft = Draft.fresh();
                    openComposer(
                      n,
                      Draft(
                        id: draft.id,
                        started: draft.started,
                        updated: draft.updated,
                        body: post['body'] as String,
                        tags: tags
                            .map((tag) => tag['label'] as String)
                            .toList(),
                        postId: id,
                        quoteId: post['quoteId'] as String?,
                        version: post['version'] as int,
                      ),
                    );
                  },
                ),
              ),
              Builder(
                builder: (sheet) => SettingsRow(
                  '投稿を削除',
                  icon: Icons.delete_outline,
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(_remove(context));
                  },
                ),
              ),
            ],
            if (author != api.owner) ...[
              Builder(
                builder: (sheet) => SettingsRow(
                  '投稿を報告',
                  icon: Icons.flag_outlined,
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(reportForum(context, api, 'post', id));
                  },
                ),
              ),
              Builder(
                builder: (sheet) => SettingsRow(
                  'ブロックする',
                  icon: Icons.block,
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(blockForum(context, n, author));
                  },
                ),
              ),
            ],
          ]),
        ),
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.edge),
            child: Wrap(
              children: [
                for (final tag in tags)
                  TextButton(
                    onPressed: () => n.open<void>(
                      Destination(Screen.tagged, tag['id'] as String),
                    ),
                    child: Text('#${tag['label']}'),
                  ),
              ],
            ),
          ),
        if (post['quoteId'] != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.edge),
            child: quote == null
                ? const Text('引用元の投稿は表示できません')
                : TextButton(
                    onPressed: () => n.open<void>(
                      Destination(Screen.post, quote['id'] as String),
                    ),
                    child: Text(
                      '${quote['nickname']}\n${quote['body']}',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
      ],
    );
  }

  Future<void> _remove(BuildContext context) async {
    if (!await confirmForum(context, 'この投稿を削除しますか？', '削除する') ||
        !context.mounted) {
      return;
    }
    try {
      await navigation.community!.write(
        '/v1/posts/${post['id']}',
        'DELETE',
        headers: {
          'if-match': '"${post['version']}"',
          'idempotency-key': draftId(),
        },
      );
      navigation.back();
    } on MembershipFailure catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
}

Future<bool> confirmForum(
  BuildContext context,
  String text,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<void> blockForum(
  BuildContext context,
  NavigationController n,
  String id,
) async {
  if (!await confirmForum(context, 'このユーザーをブロックしますか？', 'ブロックする') ||
      !context.mounted) {
    return;
  }
  try {
    await n.community!.write('/v1/me/blocks/$id', 'PUT');
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ブロックしました。')));
    }
  } on MembershipFailure catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

const reportReasons = {
  'spam': 'スパム',
  'disruption': '迷惑行為',
  'harassment': '誹謗中傷・嫌がらせ',
  'inappropriate': '不適切なコンテンツ',
  'privacy': '個人情報の公開',
  'impersonation': 'なりすまし',
  'copyright': '著作権侵害',
  'other': 'その他',
};

Future<void> reportForum(
  BuildContext context,
  Community api,
  String kind,
  String target,
) async {
  final result = await showDialog<Json>(
    context: context,
    builder: (_) => const _ReportForm(),
  );
  if (result == null || !context.mounted) return;
  try {
    await api.write(
      '/v1/reports',
      'POST',
      body: {'kind': kind, 'targetId': target, ...result},
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('報告を受け付けました。')));
    }
  } on MembershipFailure catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _ReportForm extends StatefulWidget {
  const _ReportForm();
  @override
  State<_ReportForm> createState() => _ReportState();
}

class _ReportState extends State<_ReportForm> {
  String category = 'spam', detail = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('報告する'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<String>(
          isExpanded: true,
          value: category,
          items: [
            for (final entry in reportReasons.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Text(
                  entry.value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) setState(() => category = value);
          },
        ),
        TextField(
          maxLength: 500,
          maxLines: 3,
          onChanged: (value) => detail = value,
          decoration: const InputDecoration(labelText: '詳細（任意）'),
        ),
        const Text('報告は運営確認のために送信されます。'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      TextButton(
        onPressed: () =>
            Navigator.pop(context, {'category': category, 'detail': detail}),
        child: const Text('報告を送信'),
      ),
    ],
  );
}
