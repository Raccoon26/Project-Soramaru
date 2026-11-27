import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../membership/gateway.dart';
import '../navigation/destinations.dart';
import '../network/api_client.dart';
import '../photos/photo_jobs.dart';
import '../photos/photo_view.dart';
import '../photos/selection.dart';
import '../navigation/navigation_app.dart';
import '../ui/controls.dart';
import '../ui/design.dart';
import 'community.dart';
import 'drafts.dart';
import 'forum.dart';
import 'tag_picker.dart';

String postText(String raw) => raw.replaceAll(RegExp(r'\r\n?'), '\n');
int postLength(String raw) => postText(raw).characters.length;

class ForumComposer extends StatefulWidget {
  const ForumComposer(this.navigation, this.initial, {super.key});
  final NavigationController navigation;
  final Draft? initial;
  @override
  State<ForumComposer> createState() => _ForumComposerState();
}

class _ForumComposerState extends State<ForumComposer>
    with WidgetsBindingObserver {
  late final Community api = widget.navigation.community!;
  late final String owner = api.owner!;
  late Draft seed = widget.initial ?? Draft.fresh();
  late final body = TextEditingController(text: seed.body);
  final tag = TextEditingController();
  late List<String> tags = [...seed.tags];
  late List<String> attachments = [...seed.attachments];
  TransferCancel? transfer;
  double? progress;
  late String? pending = seed.requestKey;
  Future<Json>? quotePreview;
  Timer? debounce;
  bool busy = false, dirty = false;
  String? status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quote();
  }

  void _quote() {
    final id = seed.quoteId;
    final album = seed.quoteAlbumId;
    quotePreview = id != null
        ? api.read('/v1/posts/$id')
        : album == null
        ? null
        : api.read('/v1/gallery/$album');
  }

  Draft _capture() => Draft(
    id: seed.id,
    started: seed.started,
    updated: DateTime.now().millisecondsSinceEpoch,
    body: body.text,
    tags: [...tags],
    postId: seed.postId,
    version: seed.version,
    quoteId: seed.quoteId,
    quoteAlbumId: seed.quoteAlbumId,
    requestKey: pending,
    attachments: [...attachments],
  );

  Future<void> _save({bool feedback = false}) async {
    if (api.owner != owner || (!dirty && !feedback)) return;
    debounce?.cancel();
    final value = _capture();
    dirty = false;
    try {
      await api.drafts.save(owner, value);
      if (feedback && mounted) setState(() => status = '下書きを保存しました。');
    } catch (_) {
      dirty = true;
      if (mounted) setState(() => status = '下書きを保存できませんでした。');
      if (busy) rethrow;
    }
  }

  void _changed() {
    dirty = true;
    setState(() => status = null);
    debounce?.cancel();
    debounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_save()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_save());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    unawaited(_save());
    transfer?.cancel();
    body.dispose();
    tag.dispose();
    super.dispose();
  }

  void _addTag() {
    final value = tag.text.trim().replaceFirst(RegExp(r'^[#＃]'), '');
    if (value.isEmpty || value.runes.length > 48 || tags.length >= 10) {
      setState(() => status = 'タグは48文字以内、10個まで追加できます。');
      return;
    }
    if (tags.any((t) => tagKey(t) == tagKey(value))) {
      setState(() => status = '同じタグが追加されています。');
      return;
    }
    tags.add(value);
    tag.clear();
    _changed();
  }

  Future<void> _selectTags() async {
    final navigation = widget.navigation;
    navigation.choosingTags = [...tags];
    final selected = await navigation.open<List<String>>(
      const Destination(Screen.pickTag),
    );
    navigation.choosingTags = null;
    if (!mounted || selected == null || api.owner != owner) return;
    tags
      ..clear()
      ..addAll(selected);
    _changed();
  }

  Future<void> _selectPhotos() async {
    final navigation = widget.navigation;
    // Persist the draft before opening an OS picker, which can recreate the app.
    dirty = true;
    await _save();
    if (!mounted || api.owner != owner) return;
    navigation.selectingPhotos = SelectionRequest(seed.id, [
      ...attachments,
    ], seed.postId);
    final selected = await navigation.open<List<String>>(
      const Destination(Screen.pickPhoto),
    );
    navigation.selectingPhotos = null;
    if (!mounted || selected == null || api.owner != owner) return;
    final removed = attachments.where((id) => !selected.contains(id)).toList();
    attachments = selected;
    _changed();
    await _save();
    if (dirty || api.owner != owner) return;
    for (final id in removed) {
      unawaited(PhotoJobs(api).discard(seed.id, id).catchError((Object _) {}));
    }
  }

  Future<void> _submit() async {
    if (busy) return;
    final text = postText(body.text);
    if ((text.trim().isEmpty &&
            seed.quoteId == null &&
            seed.quoteAlbumId == null &&
            attachments.isEmpty) ||
        postLength(text) > 10000 ||
        utf8.encode(text).length > 360000 ||
        text.characters.any((c) => c.runes.length > 64)) {
      setState(() => status = '本文を入力し、10,000文字以内にしてください。');
      return;
    }
    setState(() {
      busy = true;
      status = null;
    });
    final cancel = TransferCancel();
    transfer = cancel;
    try {
      final photos = <String>[];
      final jobs = PhotoJobs(api);
      if (attachments.isNotEmpty) {
        dirty = true;
        await _save();
        for (final (index, id) in attachments.indexed) {
          if (cancel.cancelled) throw const MembershipFailure('cancelled');
          final remote = await jobs.uploadDraft(seed.id, id, cancel, (value) {
            if (mounted) {
              setState(() => progress = (index + value) / attachments.length);
            }
          });
          photos.add(remote);
        }
      }
      pending ??= draftId();
      dirty = true;
      await _save();
      if (cancel.cancelled) throw const MembershipFailure('cancelled');
      final editing = seed.postId != null;
      await api.write(
        editing ? '/v1/posts/${seed.postId}' : '/v1/posts',
        editing ? 'PATCH' : 'POST',
        headers: {
          'idempotency-key': pending!,
          if (editing) 'if-match': '"${seed.version}"',
        },
        body: {
          'body': text,
          'tags': tags,
          if (api.hasPhotos) 'attachments': photos,
          if (!editing) 'quoteId': seed.quoteId,
          if (!editing && seed.quoteAlbumId != null)
            'quoteAlbumId': seed.quoteAlbumId,
        },
      );
      dirty = false;
      if (api.owner == owner) await api.drafts.remove(owner, seed.id);
      if (mounted) widget.navigation.back();
    } catch (e) {
      if (e is MembershipFailure &&
          e.status >= 400 &&
          e.status < 500 &&
          e.status != 429) {
        pending = null;
        dirty = true;
        unawaited(_save());
      }
      if (mounted) {
        setState(
          () => status = e is MembershipFailure ? e.message : '投稿を送信できませんでした。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
          transfer = null;
        });
      }
    }
  }

  Future<void> _chooseDraft() async {
    await _save();
    final selected = await api.drafts.list(owner);
    if (!mounted || api.owner != owner) return;
    final next = await showModalBottomSheet<Draft>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _SavedDrafts(selected, remove: (id) => api.drafts.remove(owner, id)),
    );
    if (next == null || !mounted || api.owner != owner) return;
    debounce?.cancel();
    setState(() {
      seed = next;
      pending = next.requestKey;
      body.text = next.body;
      tags = [...next.tags];
      attachments = [...next.attachments];
      dirty = false;
      status = null;
      _quote();
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = busy || pending != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(seed.postId == null ? '記事を作成' : '投稿を編集'),
        leading: IconButton(
          tooltip: 'キャンセル',
          icon: const Icon(Icons.close),
          onPressed: busy
              ? null
              : () async {
                  await _save();
                  if (mounted) widget.navigation.back();
                },
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Space.edge),
          children: [
            TextButton(
              onPressed: busy ? null : _chooseDraft,
              child: const Text('下書き一覧'),
            ),
            TextButton(
              onPressed: locked ? null : _selectTags,
              child: const Text('タグを探す'),
            ),
            if (quotePreview case final preview?)
              FutureBuilder<Json>(
                future: preview,
                builder: (context, snapshot) => Text(
                  snapshot.hasData
                      ? '引用元　${snapshot.requireData[seed.quoteAlbumId == null ? 'body' : 'title']}'
                      : '引用元の投稿は表示できません',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            TextField(
              controller: body,
              enabled: !locked,
              minLines: 5,
              maxLines: 12,
              onChanged: (_) => _changed(),
              decoration: const InputDecoration(
                labelText: '本文',
                alignLabelWithHint: true,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${postLength(body.text)} / 10,000'),
            ),
            const SizedBox(height: Space.gap),
            TextField(
              controller: tag,
              enabled: !locked,
              onSubmitted: (_) => _addTag(),
              decoration: InputDecoration(
                labelText: 'タグを追加',
                suffixIcon: IconButton(
                  tooltip: 'タグを追加',
                  onPressed: locked ? null : _addTag,
                  icon: const Icon(Icons.add),
                ),
              ),
            ),
            Wrap(
              spacing: Space.sm,
              children: [
                for (final name in tags)
                  InputChip(
                    label: Text('#$name'),
                    onDeleted: locked
                        ? null
                        : () {
                            tags.remove(name);
                            _changed();
                          },
                  ),
              ],
            ),
            const SizedBox(height: Space.gap),
            if (api.hasPhotos) ...[
              OutlinedButton(
                onPressed: locked ? null : _selectPhotos,
                child: Text('写真を追加（${attachments.length}/10）'),
              ),
              if (attachments.isNotEmpty)
                SizedBox(
                  height: 74,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: attachments.length,
                    itemBuilder: (context, index) {
                      final id = attachments[index];
                      return SizedBox(
                        width: 74,
                        child: isRemotePhoto(id) && seed.postId != null
                            ? RemotePhoto(
                                api,
                                PhotoPointer('post', seed.postId!, id),
                                fit: BoxFit.cover,
                              )
                            : LocalPhotoPreview(PhotoJobs(api), seed.id, id),
                      );
                    },
                  ),
                ),
              const Text('コレクションは準備中です。'),
            ] else
              const Text('写真・コレクションの添付は準備中です。'),
            if (pending != null && !busy)
              const Text('送信結果を確認するため、同じ内容で再試行できます。'),
            if (status case final message?)
              Semantics(liveRegion: true, child: Text(message)),
            const SizedBox(height: Space.gap),
            Wrap(
              runSpacing: Space.sm,
              spacing: Space.sm,
              children: [
                ActionButton(
                  '下書き保存',
                  kind: ButtonKind.secondary,
                  onPressed: busy ? null : () => _save(feedback: true),
                ),
                ActionButton(
                  pending != null && !busy
                      ? '同じ内容で再試行'
                      : seed.postId == null
                      ? '投稿する'
                      : '保存する',
                  onPressed: busy ? null : _submit,
                ),
              ],
            ),
            if (busy) ...[
              LinearProgressIndicator(
                value: progress,
                semanticsLabel: '写真と投稿の送信',
              ),
              if (attachments.isNotEmpty)
                TextButton(
                  onPressed: () => transfer?.cancel(),
                  child: const Text('アップロードを中止'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SavedDrafts extends StatefulWidget {
  const _SavedDrafts(this.entries, {required this.remove});
  final List<Draft> entries;
  final Future<void> Function(String) remove;
  @override
  State<_SavedDrafts> createState() => _SavedDraftsState();
}

class _SavedDraftsState extends State<_SavedDrafts> {
  late final rows = [...widget.entries];
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: ListView(
        children: [
          const ListTile(title: Text('下書き一覧')),
          if (rows.isEmpty) const ListTile(title: Text('保存された下書きはありません。')),
          for (final entry in rows)
            ListTile(
              title: Text(
                entry.body.isEmpty ? '引用の下書き' : entry.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(whenPosted(entry.updated)),
              onTap: () => Navigator.pop(context, entry),
              trailing: IconButton(
                tooltip: '下書きを削除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirmForum(context, 'この下書きを削除しますか？', '削除する')) {
                    return;
                  }
                  await widget.remove(entry.id);
                  if (mounted) setState(() => rows.remove(entry));
                },
              ),
            ),
        ],
      ),
    ),
  );
}
