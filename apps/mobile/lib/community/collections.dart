import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../membership/gateway.dart';
import '../navigation/destinations.dart';
import '../navigation/navigation_app.dart';
import '../photos/photo_view.dart';
import 'community.dart';
import 'discovery.dart';
import 'forum.dart';

Future<String?> folderName(BuildContext context, {String? old}) async {
  final controller = TextEditingController(text: old);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(old == null ? 'フォルダーを作成' : 'フォルダー名を変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'フォルダー名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(context, value);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

Future<Json?> chooseFolder(
  BuildContext context,
  Community api, {
  String? exclude,
}) => showModalBottomSheet<Json>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .64,
      child: DiscoveryPage(
        api,
        '/v1/collections',
        header: ListTile(
          title: const Text('フォルダーを選択'),
          trailing: IconButton(
            tooltip: 'フォルダーを作成',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: () async {
              final name = await folderName(context);
              if (name == null || !context.mounted) return;
              try {
                final row = await api.write(
                  '/v1/collections',
                  'POST',
                  body: {'id': discoveryId(), 'title': name},
                );
                if (context.mounted) Navigator.pop(context, row);
              } catch (error) {
                if (context.mounted) {
                  discoveryMessage(context, discoveryError(error));
                }
              }
            },
          ),
        ),
        empty: 'フォルダーがありません。フォルダーを作成してください。',
        row: (context, row) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(row['title'] as String),
          enabled: row['id'] != exclude,
          onTap: () => Navigator.pop(context, row),
        ),
      ),
    ),
  ),
);

Future<void> saveReference(
  BuildContext context,
  Community api,
  Json reference,
) async {
  final owner = api.owner;
  final folder = await chooseFolder(context, api);
  if (folder == null || owner != api.owner || !context.mounted) return;
  try {
    await api.write(
      '/v1/collections/${folder['id']}/entries',
      'POST',
      body: reference,
    );
    if (context.mounted) discoveryMessage(context, 'コレクションに追加しました。');
  } catch (error) {
    if (context.mounted) discoveryMessage(context, discoveryError(error));
  }
}

class FolderList extends StatelessWidget {
  const FolderList(this.navigation, {this.owner, super.key});
  final NavigationController navigation;
  final String? owner;
  @override
  Widget build(BuildContext context) {
    final api = navigation.community!;
    final own = owner == null || owner == api.owner;
    return DiscoveryPage(
      api,
      own ? '/v1/collections' : '/v1/members/$owner/collections',
      empty: own ? 'フォルダーはありません。' : '公開されているコレクションはありません。',
      header: own
          ? TextButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('フォルダーを作成'),
              onPressed: () async {
                final name = await folderName(context);
                if (name == null || !context.mounted) return;
                try {
                  await api.write(
                    '/v1/collections',
                    'POST',
                    body: {'id': discoveryId(), 'title': name},
                  );
                } catch (error) {
                  if (context.mounted) {
                    discoveryMessage(context, discoveryError(error));
                  }
                }
              },
            )
          : null,
      row: (context, row) => ListTile(
        leading: const Icon(Icons.folder_outlined),
        title: Text(row['title'] as String),
        onTap: () {
          final id = row['id'] as String;
          if (own) {
            navigation.open<void>(Destination(Screen.folder, id));
          } else {
            unawaited(
              showDialog<void>(
                context: context,
                fullscreenDialog: true,
                builder: (context) => Dialog.fullscreen(
                  child: Scaffold(
                    appBar: AppBar(title: Text(row['title'] as String)),
                    body: FolderContents(navigation, id, editable: false),
                  ),
                ),
              ),
            );
          }
        },
        trailing: own
            ? PopupMenuButton<String>(
                onSelected: (value) => _folderAction(context, api, row, value),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'rename', child: Text('名前を変更')),
                  PopupMenuItem(value: 'delete', child: Text('削除')),
                ],
              )
            : null,
      ),
    );
  }
}

Future<void> _folderAction(
  BuildContext context,
  Community api,
  Json row,
  String action,
) async {
  final path = '/v1/collections/${row['id']}';
  final headers = {'if-match': '"${row['version']}"'};
  try {
    if (action == 'rename') {
      final name = await folderName(context, old: row['title'] as String);
      if (name != null && context.mounted) {
        await api.write(path, 'PATCH', headers: headers, body: {'title': name});
      }
    } else if (await confirmForum(
          context,
          'フォルダーと保存した参照を削除しますか？元の投稿やコンテンツは残ります。',
          '削除する',
        ) &&
        context.mounted) {
      await api.write(path, 'DELETE', headers: headers);
    }
  } catch (error) {
    if (context.mounted) discoveryMessage(context, discoveryError(error));
  }
}

class FolderContents extends StatefulWidget {
  const FolderContents(
    this.navigation,
    this.id, {
    this.editable = true,
    super.key,
  });
  final NavigationController navigation;
  final String id;
  final bool editable;
  @override
  State<FolderContents> createState() => _FolderContentsState();
}

class _FolderContentsState extends State<FolderContents> {
  final selected = <String>{};
  bool editing = false;
  bool byRecent = true;
  bool busy = false;
  Community get api => widget.navigation.community!;
  Future<void> _apply({required bool move}) async {
    if (busy || selected.isEmpty) return;
    final target = move
        ? await chooseFolder(context, api, exclude: widget.id)
        : null;
    if (!mounted) return;
    if (move && target == null) return;
    if (!move && !await confirmForum(context, '選択した項目をフォルダーから外しますか？', '外す')) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final result = await api.write(
        '/v1/collections/${widget.id}/entries',
        'PATCH',
        body: {
          'ids': selected.toList(),
          if (target != null) 'destination': target['id'],
        },
      );
      if (mounted) {
        if (move && (result['moved'] as int? ?? 0) < selected.length) {
          discoveryMessage(context, '重複または利用できない項目は移動しませんでした。');
        }
        setState(() {
          selected.clear();
          editing = false;
        });
      }
    } catch (error) {
      if (mounted) discoveryMessage(context, discoveryError(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DiscoveryPage(
    api,
    '/v1/collections/${widget.id}',
    params: {'sort': byRecent ? 'newest' : 'oldest'},
    header: Wrap(
      children: [
        TextButton(
          onPressed: () => setState(() => byRecent = !byRecent),
          child: Text(byRecent ? '新しい順' : '古い順'),
        ),
        if (widget.editable)
          TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                    editing = !editing;
                    selected.clear();
                  }),
            child: Text(editing ? 'キャンセル' : '選択'),
          ),
        if (editing) ...[
          TextButton(
            onPressed: selected.isEmpty || busy
                ? null
                : () => _apply(move: true),
            child: const Text('移動'),
          ),
          TextButton(
            onPressed: selected.isEmpty || busy
                ? null
                : () => _apply(move: false),
            child: const Text('外す'),
          ),
        ],
      ],
    ),
    row: (context, row) {
      final id = row['id'] as String;
      final album = row['albumId'] as String?;
      final origin = album ?? row['postId'] as String;
      final media = row['photoId'] as String?;
      final kind = album == null ? 'post' : 'album';
      void open() {
        if (media != null) {
          showPhotoViewer(context, api, [PhotoPointer(kind, origin, media)], 0);
        } else {
          openSearchItem(widget.navigation, kind, origin);
        }
      }

      return ListTile(
        title: Text(
          row['label']?.toString().isNotEmpty == true
              ? row['label'] as String
              : searchLabels[kind]!,
        ),
        leading: media == null
            ? Icon(
                album == null
                    ? Icons.article_outlined
                    : Icons.collections_outlined,
              )
            : SizedBox.square(
                dimension: 44,
                child: RemotePhoto(
                  api,
                  PhotoPointer(kind, origin, media),
                  fit: BoxFit.cover,
                ),
              ),
        onTap: editing ? null : open,
        trailing: editing
            ? Checkbox(
                value: selected.contains(id),
                onChanged: busy
                    ? null
                    : (value) => setState(() {
                        if (value == true && selected.length < 20) {
                          selected.add(id);
                        } else {
                          selected.remove(id);
                        }
                      }),
              )
            : null,
      );
    },
  );
}

Future<String?> selectCollectionPhoto(
  BuildContext context,
  Community api,
  List<String> added,
) async {
  final folder = await chooseFolder(context, api);
  if (folder == null || !context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: DiscoveryPage(
          api,
          '/v1/collections/${folder['id']}',
          empty: '添付できる写真がありません。',
          row: (context, row) {
            final photo = row['photoId'] as String?;
            if (photo == null) return const SizedBox.shrink();
            final enabled = row['attachable'] == true && !added.contains(photo);
            final album = row['albumId'] as String?;
            final post = row['postId'] as String?;
            return ListTile(
              leading: SizedBox.square(
                dimension: 48,
                child: RemotePhoto(
                  api,
                  PhotoPointer(
                    album == null ? 'post' : 'album',
                    album ?? post!,
                    photo,
                  ),
                  fit: BoxFit.cover,
                ),
              ),
              title: Text(row['label'] as String),
              enabled: enabled,
              subtitle: enabled
                  ? null
                  : Text(added.contains(photo) ? '追加済み' : '元の写真は添付できません。'),
              onTap: enabled ? () => Navigator.pop(context, photo) : null,
            );
          },
        ),
      ),
    ),
  );
}
