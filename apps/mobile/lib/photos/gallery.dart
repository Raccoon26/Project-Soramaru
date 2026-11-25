import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../community/community.dart';
import '../community/forum.dart';
import '../membership/gateway.dart';
import '../navigation/destinations.dart';
import '../navigation/navigation_app.dart';
import '../ui/design.dart';
import 'photo_view.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage(this.navigation, {super.key});
  final NavigationController navigation;
  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  late final Community api = widget.navigation.community!;
  final albums = <String, Json>{};
  String? cursor;
  bool busy = false;
  Object? error;
  int token = 0;

  @override
  void initState() {
    super.initState();
    api.addListener(_reload);
    unawaited(_load(reset: true));
  }

  void _reload() => unawaited(_load(reset: true));

  Future<void> _load({bool reset = false}) async {
    if (!reset && (busy || cursor == null)) return;
    final stamp = ++token;
    setState(() {
      busy = true;
      error = null;
      if (reset) {
        albums.clear();
        cursor = null;
      }
    });
    try {
      final page = await api.read('/v1/gallery', {
        'limit': '20',
        'cursor': ?cursor,
      });
      if (!mounted || stamp != token) return;
      setState(() {
        for (final album in (page['items'] as List).whereType<Json>()) {
          albums[album['id'] as String] = album;
        }
        cursor = albums.length >= 200 ? null : page['nextCursor'] as String?;
      });
    } catch (e) {
      if (mounted && stamp == token) setState(() => error = e);
    } finally {
      if (mounted && stamp == token) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    api.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () => _load(reset: true),
    child: CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(Space.edge),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: .62,
            ),
            itemCount: albums.length,
            itemBuilder: (context, index) {
              final album = albums.values.elementAt(index),
                  id = album['id'] as String;
              final cover = album['coverId'] as String?;
              return InkWell(
                onTap: () =>
                    widget.navigation.open<void>(Destination(Screen.album, id)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 3 / 4,
                          child: cover != null
                              ? RemotePhoto(
                                  api,
                                  PhotoPointer('album', id, cover),
                                  fit: BoxFit.cover,
                                )
                              : const Center(
                                  child: Icon(Icons.collections_outlined),
                                ),
                        ),
                      ),
                    ),
                    Text(
                      album['title'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '公式　${album['count']}枚',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      whenPosted(album['publishedAt']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.edge),
              child: busy
                  ? const CircularProgressIndicator(semanticsLabel: '読み込み中')
                  : error != null
                  ? forumError(error!, () => _load(reset: cursor == null))
                  : albums.isEmpty
                  ? const Text('公開中のアルバムはありません。')
                  : cursor != null
                  ? TextButton(onPressed: _load, child: const Text('次を読み込む'))
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    ),
  );
}

class GalleryAlbum extends StatefulWidget {
  const GalleryAlbum(
    this.navigation,
    this.id, {
    this.viewer = false,
    super.key,
  });
  final NavigationController navigation;
  final String id;
  final bool viewer;
  @override
  State<GalleryAlbum> createState() => _GalleryAlbumState();
}

class _GalleryAlbumState extends State<GalleryAlbum> {
  late final Community api = widget.navigation.community!;
  late Future<Json> result;

  @override
  void initState() {
    super.initState();
    result = api.read('/v1/gallery/${widget.id}');
    api.addListener(_reload);
  }

  void _reload() {
    if (mounted) setState(() => result = api.read('/v1/gallery/${widget.id}'));
  }

  @override
  void dispose() {
    api.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: result,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CircularProgressIndicator(semanticsLabel: '読み込み中'),
        );
      }
      if (snapshot.hasError) return forumError(snapshot.error!, _reload);
      final album = snapshot.requireData;
      final photos = (album['photos'] as List)
          .whereType<String>()
          .map((id) => PhotoPointer('album', widget.id, id))
          .toList();
      if (widget.viewer && photos.isNotEmpty) {
        return PhotoViewer(
          api,
          photos,
          initial: widget.navigation.albumPhotoIndex,
        );
      }
      return ListView(
        padding: const EdgeInsets.all(Space.edge),
        children: [
          Text(album['title'] as String, style: TypeStyles.heading),
          Text('公式　${album['author']}　${photos.length}枚'),
          Text(whenPosted(album['publishedAt'])),
          if (photos.isEmpty)
            const Text('写真はありません。')
          else
            PhotoStrip(
              api,
              photos,
              onOpen: (index) {
                widget.navigation.albumPhotoIndex = index;
                unawaited(
                  widget.navigation.open<void>(
                    Destination(Screen.photo, widget.id),
                  ),
                );
              },
            ),
          TextButton(
            child: const Text('アルバムの操作'),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => const SafeArea(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        title: Text('アルバムをコレクションに追加'),
                        subtitle: Text('準備中'),
                      ),
                      ListTile(title: Text('アルバムを引用投稿'), subtitle: Text('準備中')),
                      ListTile(title: Text('シェア'), subtitle: Text('共有リンクは準備中')),
                      ListTile(
                        title: Text('このコンテンツの投稿を見る'),
                        subtitle: Text('準備中'),
                      ),
                      ListTile(
                        title: Text('コレクションしているユーザー'),
                        subtitle: Text('準備中'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
