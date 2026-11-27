import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../membership/gateway.dart';
import '../membership/controller.dart';
import '../navigation/destinations.dart';
import '../navigation/navigation_app.dart';
import '../photos/photo_view.dart';
import '../ui/design.dart';
import 'community.dart';
import 'forum.dart';

ChoiceChip discoveryChoice(
  String label,
  bool selected,
  ValueChanged<bool> select,
) => ChoiceChip(
  label: Text(label),
  selected: selected,
  selectedColor: Palette.warm,
  backgroundColor: Palette.surface,
  checkmarkColor: Palette.pinkContrast,
  side: BorderSide(
    color: selected ? Palette.pinkContrast : Palette.border,
    width: selected ? 2 : 1,
  ),
  labelStyle: const TextStyle(color: Palette.ink),
  onSelected: select,
);

const searchLabels = {
  'post': '投稿',
  'member': 'ユーザー',
  'tag': 'タグ',
  'album': 'アルバム',
};

void openSearchItem(NavigationController navigation, String kind, String id) {
  final screen = switch (kind) {
    'member' => Screen.user,
    'tag' => Screen.tagged,
    'album' => Screen.album,
    _ => Screen.post,
  };
  navigation.open<void>(Destination(screen, id));
}

void showDiscovery(BuildContext context, String title, Widget content) {
  unawaited(
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: content,
        ),
      ),
    ),
  );
}

String normalizeSearch(String text) => unicode
    .nfkc(text)
    .toLowerCase()
    .replaceAllMapped(
      RegExp(r'[\u30a1-\u30f6\u30fd-\u30fe]'),
      (match) => String.fromCharCode(match[0]!.codeUnitAt(0) - 0x60),
    )
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String discoveryId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return [
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20),
  ].join('-');
}

void discoveryMessage(BuildContext context, String text) {
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }
}

String discoveryError(Object error) =>
    error is MembershipFailure ? error.message : '処理を完了できませんでした。';

class FavoriteToggle extends StatefulWidget {
  const FavoriteToggle(this.api, this.kind, this.id, {this.initial, super.key});
  final Community api;
  final String kind, id;
  final bool? initial;

  @override
  State<FavoriteToggle> createState() => _FavoriteToggleState();
}

class _FavoriteToggleState extends State<FavoriteToggle> {
  bool? saved;
  bool busy = false;
  String get path => '/v1/favorites/${widget.kind}/${widget.id}';
  @override
  void initState() {
    super.initState();
    saved = widget.initial;
    if (saved == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final state = await widget.api.read(path);
      if (mounted) setState(() => saved = state['saved'] == true);
    } on Object {
      if (mounted) setState(() => saved = null);
    }
  }

  Future<void> _toggle() async {
    if (busy) return;
    final prior = saved;
    setState(() => busy = true);
    try {
      if (prior == null) {
        await _load();
      } else {
        await widget.api.write(path, prior ? 'DELETE' : 'PUT');
        if (mounted) setState(() => saved = !prior);
      }
    } catch (error) {
      if (mounted) discoveryMessage(context, discoveryError(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = saved == true;
    final label = saved == null
        ? 'お気に入りの状態を確認'
        : selected
        ? 'お気に入りから外す'
        : 'お気に入りに追加';
    return IconButton(
      tooltip: label,
      isSelected: selected,
      icon: Icon(selected ? Icons.bookmark : Icons.bookmark_border),
      onPressed: busy ? null : _toggle,
    );
  }
}

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage(
    this.api,
    this.path, {
    required this.row,
    this.params = const {},
    this.header,
    this.footer,
    this.empty = '表示する項目はありません。',
    super.key,
  });
  final Community api;
  final String path, empty;
  final Map<String, String> params;
  final Widget? header, footer;
  final Widget Function(BuildContext, Json) row;

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage>
    with WidgetsBindingObserver {
  final rows = <String, Json>{};
  Json? page;
  String? next;
  Object? error;
  bool busy = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.api.addListener(_reset);
    _reset();
  }

  @override
  void didUpdateWidget(DiscoveryPage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path ||
        old.params.toString() != widget.params.toString()) {
      _reset();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reset();
  }

  void _reset() => unawaited(_load(reset: true));
  Future<void> _load({bool reset = false}) async {
    if (!reset && (busy || next == null)) return;
    final id = ++generation;
    final owner = widget.api.owner;
    final cursor = reset ? null : next;
    setState(() {
      if (reset) {
        rows.clear();
        page = null;
        next = null;
      }
      error = null;
      busy = true;
    });
    try {
      final data = await widget.api.read(widget.path, {
        ...widget.params,
        'cursor': ?cursor,
      });
      if (!mounted || generation != id || owner != widget.api.owner) return;
      setState(() {
        final items = (data['items'] as List? ?? []).whereType<Json>();
        for (final row in items) {
          rows[row['id'] as String] = row;
        }
        page = data;
        next = rows.length >= 400 ? null : data['nextCursor'] as String?;
      });
    } catch (problem) {
      if (mounted && generation == id) setState(() => error = problem);
    } finally {
      if (mounted && generation == id) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.api.removeListener(_reset);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.api.account,
    builder: (context, _) {
      if (widget.api.account.phase != MemberPhase.active) {
        return const Center(child: Text('会員の利用状態をご確認ください。'));
      }
      return _visible(context);
    },
  );

  Widget _visible(BuildContext context) {
    final entries = rows.values.toList();
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          Space.edge,
          Space.sm,
          Space.edge,
          72,
        ),
        itemCount: entries.length + 3,
        itemBuilder: (context, index) {
          if (index == 0) {
            final captured = page?['capturedAt'];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?widget.header,
                if (captured is int) Text('集計日時　${whenPosted(captured)}'),
                if (page?['stale'] == true && captured != null)
                  const Text('集計の更新が遅れています。'),
              ],
            );
          }
          if (index <= entries.length) {
            return DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Palette.divider)),
              ),
              child: widget.row(context, entries[index - 1]),
            );
          }
          if (index == entries.length + 2) {
            return widget.footer ?? const SizedBox.shrink();
          }
          if (busy) {
            return const Center(
              child: CircularProgressIndicator(semanticsLabel: '読み込み中'),
            );
          }
          if (error case final problem?) {
            return forumError(
              problem,
              () => unawaited(_load(reset: next == null)),
            );
          }
          if (entries.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Text(widget.empty),
            );
          }
          if (next != null) {
            return TextButton(
              onPressed: () => _load(),
              child: const Text('次を読み込む'),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage(this.navigation, {this.galleryOnly = false, super.key});
  final bool galleryOnly;
  final NavigationController navigation;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final Community api = widget.navigation.community!;
  final controller = TextEditingController();
  late String kind = widget.galleryOnly ? 'album' : 'post';
  late String activeKind = kind;
  String? submitted;
  Timer? debounce;
  Future<List<({String id, String kind, String text})>>? history;
  Future<List<Json>>? suggestions;

  @override
  void initState() {
    super.initState();
    _history();
    if (!widget.galleryOnly) {
      suggestions = Future.wait([
        api.read('/v1/tags/popular'),
        api.read('/v1/members/official', {'limit': '4'}),
      ]);
    }
  }

  void _history() {
    final owner = api.owner;
    history = owner == null ? null : api.drafts.searchHistory(owner);
  }

  void _submit({String? recordKind, String? text}) {
    final owner = api.owner;
    final value = (text ?? controller.text).trim();
    if (value.isEmpty || value.runes.length > 60 || owner == null) return;
    debounce?.cancel();
    setState(() {
      kind = recordKind ?? kind;
      activeKind = kind;
      submitted = value;
      controller.text = value;
    });
    unawaited(
      api.drafts
          .rememberSearch(owner, kind, value, normalizeSearch(value))
          .then((_) {
            if (mounted && api.owner == owner) setState(_history);
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> _forget([String? id]) async {
    final owner = api.owner;
    if (owner == null) return;
    await api.drafts.removeSearch(owner, id);
    if (mounted && api.owner == owner) setState(_history);
  }

  @override
  void dispose() {
    debounce?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: api.account,
    builder: (context, _) {
      if (api.account.phase != MemberPhase.active) {
        return const Center(child: Text('会員の利用状態をご確認ください。'));
      }
      return _visible(context);
    },
  );

  Widget _visible(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(Space.edge),
        child: Column(
          children: [
            TextField(
              controller: controller,
              maxLength: 60,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'キーワード',
                suffixIcon: IconButton(
                  tooltip: '検索',
                  icon: const Icon(Icons.search),
                  onPressed: _submit,
                ),
              ),
              onChanged: (value) {
                debounce?.cancel();
                setState(() => submitted = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            Wrap(
              spacing: Space.sm,
              children: [
                if (controller.text.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      debounce?.cancel();
                      setState(() {
                        controller.clear();
                        submitted = null;
                      });
                    },
                    child: const Text('入力を消去'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('キャンセル'),
                ),
                for (final option in searchLabels.entries.where(
                  (option) => widget.galleryOnly
                      ? option.key == 'album'
                      : option.key != 'album',
                ))
                  discoveryChoice(option.value, kind == option.key, (_) {
                    setState(() => kind = option.key);
                    debounce?.cancel();
                    if (submitted != null) {
                      debounce = Timer(const Duration(milliseconds: 400), () {
                        if (mounted) _submit();
                      });
                    }
                  }),
              ],
            ),
          ],
        ),
      ),
      Expanded(
        child: submitted != null
            ? DiscoveryPage(
                api,
                '/v1/search',
                key: ValueKey((activeKind, submitted)),
                params: {'kind': activeKind, 'q': submitted!},
                empty: '検索結果はありません。',
                row: (context, row) => ListTile(
                  title: Text(
                    row['label']?.toString().isNotEmpty == true
                        ? row['label'] as String
                        : '開く',
                  ),
                  onTap: () => openSearchItem(
                    widget.navigation,
                    activeKind,
                    row['id'] as String,
                  ),
                ),
              )
            : FutureBuilder(
                future: history,
                builder: (context, snapshot) {
                  final allRows = snapshot.data ?? [];
                  final rows = allRows.where(
                    (entry) => widget.galleryOnly
                        ? entry.kind == 'album'
                        : entry.kind != 'album',
                  );
                  return ListView(
                    padding: const EdgeInsets.all(Space.edge),
                    children: [
                      if (rows.isNotEmpty)
                        ListTile(
                          title: const Text('最近の検索'),
                          trailing: TextButton(
                            onPressed: () => _forget(),
                            child: const Text('すべて削除'),
                          ),
                        ),
                      for (final entry in rows)
                        ListTile(
                          title: Text(entry.text),
                          subtitle: Text(searchLabels[entry.kind] ?? ''),
                          onTap: () =>
                              _submit(recordKind: entry.kind, text: entry.text),
                          trailing: IconButton(
                            tooltip: '検索履歴を削除',
                            icon: const Icon(Icons.close),
                            onPressed: () => _forget(entry.id),
                          ),
                        ),
                      if (suggestions != null)
                        FutureBuilder(
                          future: suggestions,
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const SizedBox.shrink();
                            }
                            final groups = snapshot.requireData;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final (i, group) in groups.indexed)
                                  if ((group['items'] as List? ?? [])
                                      .isNotEmpty) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: Space.sm,
                                      ),
                                      child: Text(i == 0 ? 'おすすめタグ' : '公式ユーザー'),
                                    ),
                                    for (final row
                                        in (group['items'] as List)
                                            .whereType<Json>()
                                            .take(4))
                                      ListTile(
                                        title: Text(row['label'] as String),
                                        onTap: () => openSearchItem(
                                          widget.navigation,
                                          i == 0 ? 'tag' : 'member',
                                          row['id'] as String,
                                        ),
                                      ),
                                  ],
                              ],
                            );
                          },
                        ),
                    ],
                  );
                },
              ),
      ),
    ],
  );
}

class FavoriteList extends StatefulWidget {
  const FavoriteList(this.navigation, {super.key});
  final NavigationController navigation;
  @override
  State<FavoriteList> createState() => _FavoriteListState();
}

class _FavoriteListState extends State<FavoriteList> {
  String kind = 'post';
  @override
  Widget build(BuildContext context) {
    final api = widget.navigation.community!;
    return DiscoveryPage(
      api,
      '/v1/favorites',
      params: {'kind': kind},
      key: ValueKey(kind),
      header: Wrap(
        spacing: Space.sm,
        children: [
          for (final type in ['member', 'tag', 'post'])
            discoveryChoice(
              searchLabels[type]!,
              type == kind,
              (_) => setState(() => kind = type),
            ),
        ],
      ),
      row: (context, row) => ListTile(
        title: Text(row['label'] as String),
        onTap: () =>
            openSearchItem(widget.navigation, kind, row['id'] as String),
        trailing: FavoriteToggle(
          api,
          kind,
          row['id'] as String,
          initial: true,
          key: ValueKey(row['id']),
        ),
      ),
    );
  }
}

Widget popularTags(NavigationController navigation) {
  final api = navigation.community!;
  return DiscoveryPage(
    api,
    '/v1/tags/popular',
    empty: '表示できる人気のタグはありません。',
    row: (context, row) => ListTile(
      title: Text('#${row['label']}'),
      onTap: () => openSearchItem(navigation, 'tag', row['id'] as String),
      trailing: FavoriteToggle(
        api,
        'tag',
        row['id'] as String,
        initial: row['saved'] == true,
        key: ValueKey(row['id']),
      ),
    ),
  );
}

Widget managedBlocks(NavigationController navigation) {
  final api = navigation.community!;
  return DiscoveryPage(
    api,
    '/v1/me/blocks',
    empty: 'ブロックしたユーザーはいません。',
    row: (context, row) => ListTile(
      title: Text(row['label'] as String? ?? '利用できないアカウント'),
      subtitle: Text(whenPosted(row['created'])),
      trailing: TextButton(
        child: const Text('解除'),
        onPressed: () async {
          if (!await confirmForum(context, 'このユーザーのブロックを解除しますか？', '解除する')) {
            return;
          }
          try {
            await api.write('/v1/me/blocks/${row['id']}', 'DELETE');
          } catch (error) {
            if (context.mounted) {
              discoveryMessage(context, discoveryError(error));
            }
          }
        },
      ),
    ),
  );
}

class RecentAlbumShortcut extends StatefulWidget {
  const RecentAlbumShortcut(this.navigation, {super.key});
  final NavigationController navigation;
  @override
  State<RecentAlbumShortcut> createState() => _RecentAlbumShortcutState();
}

class _RecentAlbumShortcutState extends State<RecentAlbumShortcut> {
  late final Community api = widget.navigation.community!;
  late Future<Json> request;
  @override
  void initState() {
    super.initState();
    request = api.read('/v1/me/recents', {'limit': '3'});
    api.addListener(_reload);
  }

  void _reload() {
    if (mounted) {
      setState(() => request = api.read('/v1/me/recents', {'limit': '3'}));
    }
  }

  @override
  void dispose() {
    api.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: request,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox.shrink();
      }
      return Column(
        children: [
          for (final row
              in (snapshot.data?['items'] as List? ?? []).whereType<Json>())
            ListTile(
              title: Text(row['label'] as String),
              onTap: () => openSearchItem(
                widget.navigation,
                'album',
                row['id'] as String,
              ),
            ),
        ],
      );
    },
  );
}

class RecentAlbums extends StatefulWidget {
  const RecentAlbums(this.navigation, {super.key});
  final NavigationController navigation;
  @override
  State<RecentAlbums> createState() => _RecentAlbumsState();
}

class _RecentAlbumsState extends State<RecentAlbums> {
  int revision = 0;
  Future<void> _delete(
    BuildContext context,
    Community api, [
    String? id,
  ]) async {
    try {
      await api.write('/v1/me/recents${id == null ? '' : '/$id'}', 'DELETE');
      if (mounted) setState(() => revision++);
    } catch (error) {
      if (context.mounted) discoveryMessage(context, discoveryError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.navigation.community!;
    return DiscoveryPage(
      api,
      '/v1/me/recents',
      key: ValueKey(revision),
      empty: '最近見たコンテンツはありません。',
      header: Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () async {
            if (await confirmForum(context, '最近見た履歴を消去しますか？', '消去する') &&
                context.mounted) {
              await _delete(context, api);
            }
          },
          child: const Text('履歴を消去'),
        ),
      ),
      row: (context, row) {
        final id = row['id'] as String;
        return ListTile(
          title: Text(row['label'] as String),
          subtitle: Text(whenPosted(row['created'])),
          leading: row['coverId'] is String
              ? SizedBox(
                  width: 44,
                  height: 44,
                  child: RemotePhoto(
                    api,
                    PhotoPointer('album', id, row['coverId'] as String),
                    fit: BoxFit.cover,
                  ),
                )
              : null,
          trailing: IconButton(
            tooltip: '履歴から削除',
            icon: const Icon(Icons.close),
            onPressed: () => _delete(context, api, id),
          ),
          onTap: () => openSearchItem(widget.navigation, 'album', id),
        );
      },
    );
  }
}
