import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../community/community.dart';
import '../membership/gateway.dart';
import '../network/api_client.dart';

import '../ui/design.dart';

class PhotoPointer {
  const PhotoPointer(this.kind, this.parent, this.id);
  final String kind, parent, id;
  String path(bool thumb) => Uri(
    path: '/v1/media/$id',
    queryParameters: {
      'parent': kind,
      'parent_id': parent,
      'variant': thumb ? 'thumb' : 'full',
    },
  ).toString();
}

typedef _PhotoEntry = ({DateTime until, Uint8List data});

class PhotoMemory {
  // Served media stays in memory. Drafts use their separate encrypted database.
  final _items = <String, _PhotoEntry>{};
  final _requests = <String, Future<_PhotoEntry>>{};
  final _cancels = <String, TransferCancel>{};
  int _bytes = 0;
  int _generation = 0;
  static const ttl = Duration(seconds: 45);
  static const maxBytes = 6 * 1024 * 1024;

  Future<_PhotoEntry> _load(Community api, String path) {
    final entry = _items.remove(path);
    if (entry != null) {
      if (entry.until.isAfter(DateTime.now())) {
        _items[path] = entry;
        return Future.value(entry);
      }
      _bytes -= entry.data.length;
    }
    final generation = _generation;
    return _requests.putIfAbsent(path, () {
      final cancel = TransferCancel();
      _cancels[path] = cancel;
      return api.account
          .photoBytes(path, cancel: cancel)
          .then((bytes) {
            if (generation != _generation) {
              throw StateError('Photo access changed');
            }
            while (_items.isNotEmpty && _bytes + bytes.length > maxBytes) {
              _bytes -= _items.remove(_items.keys.first)!.data.length;
            }
            final result = (until: DateTime.now().add(ttl), data: bytes);
            if (bytes.length <= maxBytes) {
              _items[path] = result;
              _bytes += bytes.length;
            }
            return result;
          })
          .whenComplete(() {
            if (generation == _generation) {
              _requests.remove(path);
              _cancels.remove(path);
            }
          });
    });
  }

  void clear() {
    _generation++;
    _items.clear();
    for (final cancel in _cancels.values) {
      cancel.cancel();
    }
    _cancels.clear();
    _requests.clear();
    _bytes = 0;
  }
}

class RemotePhoto extends StatefulWidget {
  const RemotePhoto(
    this.api,
    this.pointer, {
    this.thumb = true,
    this.fit = BoxFit.contain,
    super.key,
  });
  final Community api;
  final PhotoPointer pointer;
  final bool thumb;
  final BoxFit fit;

  @override
  State<RemotePhoto> createState() => _RemotePhotoState();
}

class _RemotePhotoState extends State<RemotePhoto> {
  Future<Uint8List>? _future;
  ImageProvider<Object>? _frame;
  int _request = 0;
  Timer? _timer;
  String get path => widget.pointer.path(widget.thumb);

  @override
  void initState() {
    super.initState();
    widget.api.addListener(_invalidate);
    _load();
  }

  @override
  void didUpdateWidget(RemotePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pointer.path(oldWidget.thumb) != path) _load();
  }

  void _evict() {
    final frame = _frame;
    _frame = null;
    if (frame != null) unawaited(frame.evict());
  }

  void _load() {
    final request = ++_request;
    _timer?.cancel();
    _evict();
    _future = widget.api.photoMemory._load(widget.api, path).then((entry) {
      if (!mounted || request != _request) throw StateError('Stale photo');
      final memory = MemoryImage(entry.data);
      _frame = widget.thumb
          ? ResizeImage.resizeIfNeeded(400, null, memory)
          : memory;
      _timer = Timer(entry.until.difference(DateTime.now()), () {
        if (mounted) {
          setState(() {
            _future = null;
            _evict();
          });
        }
      });
      return entry.data;
    });
  }

  void _invalidate() {
    if (mounted) setState(_load);
  }

  @override
  void dispose() {
    _request++;
    _timer?.cancel();
    _evict();
    widget.api.removeListener(_invalidate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null) return _retry();
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: '写真を読み込み中',
              ),
            ),
          );
        }
        final frame = _frame;
        if (!snapshot.hasData || frame == null) return _retry();
        return Image(
          image: frame,
          fit: widget.fit,
          gaplessPlayback: false,
          errorBuilder: (_, _, _) => _retry(),
        );
      },
    );
  }

  Widget _retry() => Center(
    child: IconButton(
      tooltip: '写真を再読み込み',
      onPressed: () => setState(_load),
      icon: const Icon(Icons.refresh),
    ),
  );
}

class LocalPhoto extends StatefulWidget {
  const LocalPhoto(this.bytes, {required this.decodeWidth, super.key});
  final Uint8List bytes;
  final int decodeWidth;

  @override
  State<LocalPhoto> createState() => _LocalPhotoState();
}

class _LocalPhotoState extends State<LocalPhoto> {
  late ImageProvider<Object> _image = _provider();
  ImageProvider<Object> _provider() => ResizeImage.resizeIfNeeded(
    widget.decodeWidth,
    null,
    MemoryImage(widget.bytes),
  );

  @override
  void didUpdateWidget(LocalPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes ||
        oldWidget.decodeWidth != widget.decodeWidth) {
      unawaited(_image.evict());
      _image = _provider();
    }
  }

  @override
  void dispose() {
    unawaited(_image.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(image: _image, fit: BoxFit.cover);
}

class PhotoStrip extends StatelessWidget {
  const PhotoStrip(this.api, this.photos, {this.onOpen, super.key});
  final Community api;
  final List<PhotoPointer> photos;
  final ValueChanged<int>? onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 104,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: photos.length,
      separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
      itemBuilder: (context, index) => Semantics(
        label: '写真 ${index + 1} / ${photos.length}',
        button: onOpen != null,
        child: InkWell(
          onTap: onOpen == null ? null : () => onOpen!(index),
          child: SizedBox(
            width: 104,
            child: RemotePhoto(api, photos[index], fit: BoxFit.cover),
          ),
        ),
      ),
    ),
  );
}

void showPhotoViewer(
  BuildContext context,
  Community api,
  List<PhotoPointer> photos,
  int initial, {
  void Function(BuildContext, PhotoPointer)? onSave,
}) {
  if (photos.isEmpty) return;
  unawaited(
    Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            PhotoViewer(api, photos, initial: initial, onSave: onSave),
      ),
    ),
  );
}

class PhotoViewer extends StatefulWidget {
  const PhotoViewer(
    this.api,
    this.photos, {
    this.initial = 0,
    this.onSave,
    this.onMore,
    super.key,
  });
  final Community api;
  final List<PhotoPointer> photos;
  final int initial;
  final void Function(BuildContext, PhotoPointer)? onSave;
  final VoidCallback? onMore;
  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late int index = widget.initial.clamp(0, widget.photos.length - 1);
  late final PageController pages = PageController(initialPage: index);
  final transform = TransformationController();
  bool enlarged = false;
  Future<void>? grant;

  @override
  void initState() {
    super.initState();
    transform.addListener(_scaleChanged);
    grant = _grant(index);
  }

  Future<void> _grant(int page) async {
    final pointer = widget.photos[page];
    final first = (page ~/ 20) * 20;
    await widget.api.account.community(
      '/v1/media/grants',
      method: 'POST',
      body: {
        'parent': pointer.kind,
        'parentId': pointer.parent,
        'ids': widget.photos
            .skip(first)
            .take(20)
            .map((photo) => photo.id)
            .toList(),
        'variant': 'full',
      },
    );
  }

  Widget _fullPhoto(int page) => FutureBuilder<void>(
    future: grant,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CircularProgressIndicator(semanticsLabel: '写真を読み込み中'),
        );
      }
      if (snapshot.hasError) {
        final error = snapshot.error;
        return Center(
          child: TextButton(
            onPressed: () => setState(() => grant = _grant(page)),
            child: Text(
              error is MembershipFailure ? error.message : '写真を再読み込み',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        );
      }
      return RemotePhoto(widget.api, widget.photos[page], thumb: false);
    },
  );

  void _scaleChanged() {
    final scale = transform.value.getMaxScaleOnAxis() > 1.01;
    if (mounted && scale != enlarged) setState(() => enlarged = scale);
  }

  void _move(int next) {
    transform.value = Matrix4.identity();
    if (pages.hasClients) pages.jumpToPage(next);
  }

  @override
  void dispose() {
    transform.dispose();
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                color: Colors.white,
                tooltip: '閉じる',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close),
              ),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '${index + 1} / ${widget.photos.length}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              if (widget.onMore != null)
                IconButton(
                  color: Colors.white,
                  tooltip: 'アルバムの操作',
                  onPressed: widget.onMore,
                  icon: const Icon(Icons.more_horiz),
                ),
              if (widget.onSave case final save?)
                IconButton(
                  color: Colors.white,
                  tooltip: '写真をコレクションに追加',
                  onPressed: () => save(context, widget.photos[index]),
                  icon: const Icon(Icons.collections_bookmark_outlined),
                )
              else
                const SizedBox(width: 48),
            ],
          ),
          Expanded(
            child: PageView.builder(
              controller: pages,
              physics: enlarged ? const NeverScrollableScrollPhysics() : null,
              itemCount: widget.photos.length,
              onPageChanged: (page) {
                transform.value = Matrix4.identity();
                setState(() {
                  if (page ~/ 20 != index ~/ 20) grant = _grant(page);
                  index = page;
                });
              },
              itemBuilder: (context, page) {
                // Only the current image uses full-size bytes.
                if (page != index) {
                  return RemotePhoto(widget.api, widget.photos[page]);
                }
                return GestureDetector(
                  onDoubleTap: () => transform.value = enlarged
                      ? Matrix4.identity()
                      : Matrix4.diagonal3Values(2, 2, 1),
                  child: InteractiveViewer(
                    transformationController: transform,
                    maxScale: 4,
                    child: SizedBox.expand(child: _fullPhoto(page)),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            height: 68,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.photos.length,
              itemBuilder: (context, i) => Semantics(
                selected: i == index,
                label: '写真 ${i + 1}',
                button: true,
                child: InkWell(
                  onTap: () => _move(i),
                  child: Container(
                    width: 64,
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: i == index ? Colors.amber : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: RemotePhoto(
                      widget.api,
                      widget.photos[i],
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
