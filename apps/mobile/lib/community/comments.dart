import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../membership/gateway.dart';
import '../navigation/destinations.dart';
import '../navigation/navigation_app.dart';
import '../network/api_client.dart';
import '../photos/photo_jobs.dart';
import '../photos/photo_view.dart';
import '../photos/selection.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import 'community.dart';
import 'drafts.dart';
import 'forum.dart';
import 'reactions.dart';

class CommentBoard extends StatefulWidget {
  const CommentBoard(this.navigation, this.post, {this.focus, super.key});
  final NavigationController navigation;
  final String post;
  final String? focus;
  @override
  State<CommentBoard> createState() => _CommentBoardState();
}

class _ThreadPage {
  final items = <String, Json>{};
  String? cursor;
  bool loading = false;
  Object? error;
  int request = 0;
}

class _CommentBoardState extends State<CommentBoard> {
  late final Community api = widget.navigation.community!;
  late final String? owner = api.owner;
  final root = _ThreadPage();
  final threads = <String, _ThreadPage>{};
  final scroll = ScrollController();
  final input = TextEditingController();
  final focusNode = FocusNode();
  final selectedDraft = draftId();
  TransferCancel? uploading;
  String? photo, requestKey, error;
  Json? stamp, selectedParent, editing;
  Json? focused, submitted;
  List<Json>? stampItems;
  bool showStamps = false, sending = false, resolving = false;
  bool deliveryUnknown = false;
  double? progress;

  @override
  void initState() {
    super.initState();
    api.addListener(_changed);
    scroll.addListener(_nearEnd);
    focusNode.addListener(_keyboard);
    if (widget.focus != null) unawaited(_resolve());
    if (widget.post != widget.focus) unawaited(_load(null, first: true));
  }

  void _keyboard() {
    if (mounted && focusNode.hasFocus && showStamps) {
      setState(() => showStamps = false);
    }
  }

  Future<void> _resolve() async {
    final id = widget.focus;
    if (id == null) return;
    setState(() => resolving = true);
    try {
      final target = await api.read('/v1/comments/$id');
      if (!mounted || api.owner != owner) return;
      final parentPost = target['postId'] as String;
      if (widget.post == id && parentPost != id) {
        widget.navigation.resolveComment(parentPost, id);
        return;
      }
      if (parentPost != widget.post) {
        throw const MembershipFailure('not_found', 404);
      }
      final parent = target['parentId'] as String?;
      final anchor = parent == null
          ? target
          : await api.read('/v1/comments/$parent');
      if (!mounted || api.owner != owner) return;
      setState(() => focused = anchor);
      if (parent != null) {
        await _load(parent, first: true);
        final thread = threads[parent];
        if (mounted && thread != null && !thread.items.containsKey(id)) {
          setState(() => thread.items[id] = target);
        }
      }
    } catch (_) {
      if (mounted) setState(() => error = 'コメントを表示できません。');
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  void _nearEnd() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < 300 &&
        root.cursor != null) {
      unawaited(_load(null));
    }
  }

  void _changed() {
    if (!mounted || widget.post == widget.focus) return;
    setState(() {
      focused = null;
      submitted = null;
    });
    unawaited(_load(null, first: true));
    for (final id in threads.keys.toList()) {
      unawaited(_load(id, first: true));
    }
  }

  Future<void> _load(String? parent, {bool first = false}) async {
    final page = parent == null
        ? root
        : threads.putIfAbsent(parent, _ThreadPage.new);
    if (!first && (page.loading || page.cursor == null)) return;
    final request = ++page.request;
    setState(() {
      page.loading = true;
      page.error = null;
      if (first) {
        page.items.clear();
        page.cursor = null;
      }
    });
    try {
      final result = await api.read('/v1/posts/${widget.post}/comments', {
        'parent': ?parent,
        if (!first && page.cursor != null) 'cursor': page.cursor!,
      });
      if (!mounted || request != page.request || api.owner != owner) return;
      setState(() {
        for (final item in (result['items'] as List).whereType<Json>()) {
          page.items[item['id'] as String] = item;
        }
        page.cursor = result['nextCursor'] as String?;
      });
    } catch (failure) {
      if (mounted && request == page.request) {
        setState(() => page.error = failure);
      }
    } finally {
      if (mounted && request == page.request) {
        setState(() => page.loading = false);
      }
    }
  }

  Future<void> _choosePhoto() async {
    widget.navigation.selectingPhotos = SelectionRequest(
      selectedDraft,
      [?photo],
      editing?['id'] as String?,
      limit: 1,
      kind: 'comment',
    );
    final result = await widget.navigation.open<List<String>>(
      const Destination(Screen.pickPhoto),
    );
    widget.navigation.selectingPhotos = null;
    if (!mounted || result == null || api.owner != owner) return;
    final old = photo;
    setState(() {
      photo = result.firstOrNull;
      if (photo != null) stamp = null;
      requestKey = null;
    });
    if (old != null && old != photo && !isRemotePhoto(old)) {
      await PhotoJobs(api).discard(selectedDraft, old);
    }
  }

  Future<void> _toggleStamps() async {
    if (showStamps) {
      setState(() => showStamps = false);
      focusNode.requestFocus();
      return;
    }
    focusNode.unfocus();
    setState(() => showStamps = true);
    if (stampItems != null) return;
    try {
      final catalog = await api.read('/v1/stamps');
      if (mounted && api.owner == owner) {
        setState(
          () => stampItems = (catalog['items'] as List)
              .whereType<Json>()
              .toList(),
        );
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          showStamps = false;
          error = failure is MembershipFailure
              ? failure.message
              : 'スタンプを読み込めませんでした。';
        });
      }
    }
  }

  void _clear() {
    input.clear();
    requestKey = null;
    deliveryUnknown = false;
    stamp = photo = null;
    selectedParent = editing = null;
    showStamps = false;
    error = null;
  }

  Future<void> _submit() async {
    if (sending) return;
    final body = input.text.replaceAll(RegExp(r'\r\n?'), '\n');
    if ((body.trim().isEmpty && photo == null && stamp == null) ||
        body.characters.length > 1000 ||
        utf8.encode(body).length > 12000) {
      setState(() => error = '本文、写真またはスタンプを入力してください。本文は1,000文字までです。');
      return;
    }
    final item = editing;
    final parent = selectedParent?['id'] as String?;
    final local = photo;
    final cancel = TransferCancel();
    setState(() {
      sending = true;
      error = null;
      uploading = cancel;
    });
    try {
      final media = local == null
          ? null
          : await PhotoJobs(api)
                .uploadDraft(selectedDraft, local, cancel, (current) {
                  if (mounted) setState(() => progress = current);
                }, purpose: 'comment');
      if (!mounted || cancel.cancelled || api.owner != owner) return;
      requestKey ??= draftId();
      deliveryUnknown = true;
      final sent = await api.write(
        item == null
            ? '/v1/posts/${widget.post}/comments'
            : '/v1/comments/${item['id']}',
        item == null ? 'POST' : 'PATCH',
        headers: {
          'idempotency-key': requestKey!,
          if (item != null) 'if-match': '"${item['version']}"',
        },
        body: {
          'body': body,
          'stampId': stamp?['id'],
          'photoId': media,
          if (item == null) 'parentId': parent,
        },
      );
      if (owner != null) await api.drafts.remove(owner!, selectedDraft);
      if (mounted && api.owner == owner) {
        setState(() {
          _clear();
          submitted = sent;
        });
        if (sent['parentId'] case final String rootId
            when !threads.containsKey(rootId)) {
          unawaited(_load(rootId, first: true));
        }
      }
    } catch (failure) {
      if (!mounted || api.owner != owner) return;
      if (failure is MembershipFailure &&
          failure.status >= 400 &&
          failure.status < 500 &&
          failure.status != 429) {
        requestKey = null;
        deliveryUnknown = false;
      }
      setState(
        () => error = failure is MembershipFailure
            ? failure.message
            : 'コメントを送信できませんでした。',
      );
    } finally {
      if (mounted) {
        setState(() {
          sending = false;
          uploading = null;
          progress = null;
        });
      }
    }
  }

  Future<void> _delete(Json row) async {
    if (!await confirmForum(context, 'このコメントを削除しますか？', '削除する') || !mounted) {
      return;
    }
    try {
      await api.write(
        '/v1/comments/${row['id']}',
        'DELETE',
        headers: {
          'if-match': '"${row['version']}"',
          'idempotency-key': draftId(),
        },
      );
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is MembershipFailure
              ? failure.message
              : 'コメントを削除できませんでした。',
        );
      }
    }
  }

  void _actions(Json row) {
    final id = row['id'] as String, author = row['authorId'] as String;
    final mine = author == owner;
    showActions(context, 'コメントの操作', [
      if (mine) ...[
        Builder(
          builder: (sheet) => SettingsRow(
            'コメントを編集',
            icon: Icons.edit_outlined,
            onTap: () {
              Navigator.pop(sheet);
              if (sending || deliveryUnknown) return;
              setState(() {
                _clear();
                editing = row;
                input.text = row['body'] as String;
                stamp = row['stamp'] as Json?;
                photo = row['photoId'] as String?;
              });
              focusNode.requestFocus();
            },
          ),
        ),
        Builder(
          builder: (sheet) => SettingsRow(
            'コメントを削除',
            icon: Icons.delete_outline,
            onTap: () {
              Navigator.pop(sheet);
              unawaited(_delete(row));
            },
          ),
        ),
      ] else ...[
        Builder(
          builder: (sheet) => SettingsRow(
            'コメントを報告',
            icon: Icons.flag_outlined,
            onTap: () {
              Navigator.pop(sheet);
              unawaited(reportForum(context, api, 'comment', id));
            },
          ),
        ),
        Builder(
          builder: (sheet) => SettingsRow(
            'ブロックする',
            icon: Icons.block,
            onTap: () {
              Navigator.pop(sheet);
              unawaited(blockForum(context, widget.navigation, author));
            },
          ),
        ),
      ],
    ]);
  }

  Widget _row(Json row, {bool reply = false}) {
    final id = row['id'] as String;
    final removed = row['removed'] == true;
    final children = row['commentCount'] as int? ?? 0;
    final author = row['authorId'] as String?;
    final image = row['avatarMediaId'] as String?;
    final media = row['photoId'] as String?;
    final stamp = row['stamp'] as Json?;
    final thread = threads[id];
    final pointers = media == null
        ? const <PhotoPointer>[]
        : [PhotoPointer('comment', id, media)];
    return Column(
      key: ValueKey(id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(reply ? 30 : 12, 10, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (removed)
                const Text('削除されたコメント')
              else ...[
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (api.hasPhotos && author != null && image != null)
                      ClipOval(
                        child: SizedBox.square(
                          dimension: 28,
                          child: RemotePhoto(
                            api,
                            PhotoPointer('profile', author, image),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: author == null
                          ? null
                          : () => widget.navigation.open<void>(
                              Destination(Screen.user, author),
                            ),
                      child: Text(row['nickname'] as String? ?? 'メンバー'),
                    ),
                    if (row['category'] == 'artist' ||
                        row['category'] == 'official')
                      const Text('公式'),
                    Text(whenPosted(row['createdAt'])),
                    if (row['createdAt'] != row['updatedAt'])
                      const Text('編集済み'),
                    IconButton(
                      tooltip: 'コメントの操作',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () => _actions(row),
                    ),
                  ],
                ),
                if ((row['body'] as String).isNotEmpty)
                  Text(row['body'] as String),
                if (stamp != null) StampBadge(stamp),
                if (api.hasPhotos && pointers.isNotEmpty)
                  PhotoStrip(
                    api,
                    pointers,
                    onOpen: (position) =>
                        showPhotoViewer(context, api, pointers, position),
                  ),
              ],
              Wrap(
                children: [
                  if (!removed)
                    ReactionButton(
                      api,
                      'comment',
                      id,
                      row,
                      key: ValueKey('reaction:$id'),
                    ),
                  if (!reply && !removed)
                    TextButton(
                      onPressed: sending || deliveryUnknown
                          ? null
                          : () {
                              setState(() {
                                selectedParent = row;
                                editing = null;
                                requestKey = null;
                              });
                              focusNode.requestFocus();
                            },
                      child: const Text('返信する'),
                    ),
                  if (!reply && children > 0)
                    TextButton(
                      onPressed: () => thread == null
                          ? unawaited(_load(id, first: true))
                          : setState(() => threads.remove(id)),
                      child: Text(thread == null ? '返信 $children 件' : '返信を閉じる'),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (thread != null) ...[
          for (final entry in thread.items.values) _row(entry, reply: true),
          if (submitted case final row?
              when row['parentId'] == id &&
                  !thread.items.containsKey(row['id']))
            _row(row, reply: true),
          if (thread.loading) const LinearProgressIndicator(),
          if (thread.error case final error?)
            forumError(error, () => _load(id, first: true)),
          if (thread.cursor != null)
            TextButton(
              onPressed: () => _load(id),
              child: const Text('次の返信を読む'),
            ),
        ],
        const Divider(height: 1),
      ],
    );
  }

  Widget _composer() {
    final changed = sending || deliveryUnknown;
    final attachment = photo;
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selectedParent != null ||
                  editing != null ||
                  attachment != null ||
                  stamp != null ||
                  error != null)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (selectedParent != null)
                      Text('${selectedParent!['nickname']} に返信'),
                    if (editing != null) const Text('コメントを編集中'),
                    if (attachment != null && !isRemotePhoto(attachment))
                      SizedBox.square(
                        dimension: 46,
                        child: LocalPhotoPreview(
                          PhotoJobs(api),
                          selectedDraft,
                          attachment,
                        ),
                      ),
                    if (attachment != null)
                      TextButton(
                        onPressed: changed
                            ? null
                            : () {
                                setState(() => photo = null);
                                unawaited(
                                  PhotoJobs(api)
                                      .discard(selectedDraft, attachment),
                                );
                              },
                        child: const Text('写真を外す'),
                      ),
                    if (stamp case final chosen?)
                      StampBadge(chosen, compact: true),
                    if (stamp != null)
                      IconButton(
                        tooltip: 'スタンプを外す',
                        onPressed: changed
                            ? null
                            : () => setState(() => stamp = null),
                        icon: const Icon(Icons.close),
                      ),
                    if (selectedParent != null || editing != null)
                      TextButton(
                        onPressed: changed ? null : () => setState(_clear),
                        child: const Text('キャンセル'),
                      ),
                    if (error case final message?)
                      Semantics(liveRegion: true, child: Text(message)),
                  ],
                ),
              if (sending)
                LinearProgressIndicator(value: progress, semanticsLabel: '送信中'),
              TextField(
                controller: input,
                focusNode: focusNode,
                readOnly: changed,
                maxLines: 3,
                minLines: 1,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: selectedParent == null ? 'コメントを書く' : '返信する',
                  counterText: '',
                ),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (api.hasPhotos)
                    IconButton(
                      tooltip: '写真を追加',
                      onPressed: changed ? null : _choosePhoto,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                    ),
                  IconButton(
                    tooltip: showStamps ? 'キーボード' : 'スタンプ',
                    onPressed: changed ? null : _toggleStamps,
                    icon: Icon(
                      showStamps
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                    ),
                  ),
                  TextButton(
                    onPressed: sending ? null : _submit,
                    child: Text(deliveryUnknown ? '再試行' : '送信'),
                  ),
                  if (uploading != null && progress != null)
                    TextButton(
                      onPressed: uploading!.cancel,
                      child: const Text('アップロードを中止'),
                    ),
                ],
              ),
              if (showStamps)
                SizedBox(
                  height: (MediaQuery.sizeOf(context).height * .25).clamp(
                    100,
                    220,
                  ),
                  child: StampPanel(stampItems, stamp?['id'] as String?, (
                    selected,
                  ) {
                    final previous = photo;
                    setState(() {
                      stamp = selected;
                      photo = null;
                    });
                    if (previous != null) {
                      unawaited(
                        PhotoJobs(api).discard(selectedDraft, previous),
                      );
                    }
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    api.removeListener(_changed);
    uploading?.cancel();
    focusNode.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = <Json>[
      ?focused,
      ...root.items.values.where((row) => row['id'] != focused?['id']),
      if (submitted case final row?
          when row['parentId'] == null &&
              row['id'] != focused?['id'] &&
              !root.items.containsKey(row['id']))
        row,
    ];
    if (widget.post == widget.focus) {
      return Center(
        child: resolving
            ? const StateNotice(ViewState.loading)
            : Text(error ?? 'コメントを表示できません。'),
      );
    }
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(null, first: true),
            child: ListView.builder(
              controller: scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length + 1,
              itemBuilder: (context, index) {
                if (index < items.length) return _row(items[index]);
                if (root.loading) {
                  return const Center(child: StateNotice(ViewState.loading));
                }
                if (root.error case final problem?) {
                  return forumError(
                    problem,
                    () => _load(null, first: root.cursor == null),
                  );
                }
                return items.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('コメントはまだありません。'),
                      )
                    : const SizedBox.shrink();
              },
            ),
          ),
        ),
        if (root.error == null) _composer(),
      ],
    );
  }
}

class StampBadge extends StatelessWidget {
  const StampBadge(this.data, {this.compact = false, super.key});
  final Json data;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final (icon, tint) = switch (data['icon']) {
      'sun' => (Icons.wb_sunny_outlined, const Color(0xffffe4a1)),
      'heart' => (Icons.favorite_border, const Color(0xffffd8e8)),
      'tea' => (Icons.coffee_outlined, const Color(0xffd1efcb)),
      'party' => (Icons.celebration_outlined, const Color(0xffe5dbff)),
      'spark' => (Icons.auto_awesome_outlined, const Color(0xffffe8bb)),
      'moon' => (Icons.nights_stay_outlined, const Color(0xffd5e6ff)),
      'flower' => (Icons.local_florist_outlined, const Color(0xffffdfe0)),
      _ => (Icons.waving_hand_outlined, const Color(0xffd5f0ec)),
    };
    return Semantics(
      label: data['description'] as String,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.all(compact ? 4 : 8),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(icon, color: Palette.ink, size: compact ? 18 : 28),
            Text(
              data['label'] as String,
              style: const TextStyle(color: Palette.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class StampPanel extends StatefulWidget {
  const StampPanel(this.items, this.selected, this.onSelect, {super.key});
  final List<Json>? items;
  final String? selected;
  final ValueChanged<Json> onSelect;
  @override
  State<StampPanel> createState() => _StampPanelState();
}

class _StampPanelState extends State<StampPanel> {
  String? set;
  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items == null) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: 'スタンプを読み込み中'),
      );
    }
    if (items.isEmpty) return const Center(child: Text('使えるスタンプはありません。'));
    final sets = {
      for (final item in items)
        item['setId'] as String: item['setLabel'] as String,
    };
    final current = sets.containsKey(set) ? set : sets.keys.first;
    return Column(
      children: [
        if (sets.length > 1)
          DropdownButton<String>(
            value: current,
            items: [
              for (final entry in sets.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) => setState(() => set = value),
          ),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in items.where(
                  (item) => item['setId'] == current,
                ))
                  Semantics(
                    button: true,
                    selected: widget.selected == entry['id'],
                    label: entry['description'] as String,
                    excludeSemantics: true,
                    onTap: () => widget.onSelect(entry),
                    child: OutlinedButton(
                      onPressed: () => widget.onSelect(entry),
                      child: StampBadge(entry, compact: true),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ForumActivity extends StatefulWidget {
  const ForumActivity(this.navigation, {super.key});
  final NavigationController navigation;
  @override
  State<ForumActivity> createState() => _ForumActivityState();
}

class _ForumActivityState extends State<ForumActivity> {
  late final api = widget.navigation.community!;
  final rows = <String, Json>{};
  String? cursor;
  bool loading = false;
  Object? failure;
  int revision = 0;
  @override
  void initState() {
    super.initState();
    api.addListener(_refresh);
    unawaited(_load(true));
  }

  void _refresh() => unawaited(_load(true));
  Future<void> _load(bool first) async {
    if (!first && (loading || cursor == null)) return;
    final run = ++revision;
    setState(() {
      loading = true;
      failure = null;
      if (first) {
        rows.clear();
        cursor = null;
      }
    });
    try {
      final result = await api.read('/v1/me/activity', {'cursor': ?cursor});
      if (!mounted || run != revision) return;
      setState(() {
        for (final item in (result['items'] as List).whereType<Json>()) {
          rows[item['id'] as String] = item;
        }
        cursor = result['nextCursor'] as String?;
      });
    } catch (e) {
      if (mounted && run == revision) setState(() => failure = e);
    } finally {
      if (mounted && run == revision) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    api.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () => _load(true),
    child: ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == rows.length) {
          if (loading) {
            return const Center(child: StateNotice(ViewState.loading));
          }
          if (failure case final error?) {
            return forumError(error, () => _load(cursor == null));
          }
          if (cursor != null) {
            return Center(
              child: TextButton(
                onPressed: () => _load(false),
                child: const Text('次を読み込む'),
              ),
            );
          }
          return rows.isEmpty
              ? const Center(child: Text('最近の活動はありません。'))
              : const SizedBox.shrink();
        }
        final row = rows.values.elementAt(index),
            comment = row['commentId'] as String?;
        final label = switch (row['kind']) {
          'comment' => 'コメント',
          'reply' => '返信',
          'postLike' || 'commentLike' => 'いいね',
          _ => '投稿',
        };
        return ListTile(
          title: Text('$label  ${whenPosted(row['createdAt'])}'),
          subtitle: Text(
            row['body'] as String,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.navigation.open<void>(
            Destination(
              comment == null ? Screen.post : Screen.comments,
              row['postId'] as String,
              comment,
            ),
          ),
        );
      },
    ),
  );
}
