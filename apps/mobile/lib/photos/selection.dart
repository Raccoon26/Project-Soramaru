import 'dart:async';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';

import '../community/community.dart';
import '../community/collections.dart';
import '../ui/design.dart';
import 'photo_jobs.dart';
import 'photo_view.dart';

class SelectionRequest {
  const SelectionRequest(
    this.draft,
    this.items,
    this.postId, {
    this.limit = 10,
    this.kind = 'post',
  });
  final int limit;
  final String kind;
  final String draft;
  final List<String> items;
  final String? postId;
}

class PhotoSelection extends StatefulWidget {
  const PhotoSelection(this.api, this.request, {super.key});
  final Community api;
  final SelectionRequest request;
  @override
  State<PhotoSelection> createState() => _PhotoSelectionState();
}

class _PhotoSelectionState extends State<PhotoSelection> {
  late final PhotoJobs jobs = PhotoJobs(widget.api);
  late List<String> ids = [...widget.request.items];
  final staged = <String>[];
  bool committed = false;
  bool processing = false;
  String? message;
  String get draft => widget.request.draft;
  static const _storage = FlutterSecureStorage();
  static const _pickerSlot = 'soramaru.active-photo-picker.v1';
  String marker(String owner) => '$owner:$draft';

  Future<void> choose({bool camera = false, bool recover = false}) async {
    if (processing || ids.length >= widget.request.limit) return;
    setState(() {
      processing = true;
      message = null;
    });
    try {
      final picker = PhotoJobs.picker();
      final owner = jobs.owner;
      List<XFile> files;
      if (recover) {
        if (await _storage.read(key: _pickerSlot) != marker(owner)) return;
        final lost = await picker.retrieveLostData();
        files = lost.files ?? [];
      } else {
        await _storage.write(key: _pickerSlot, value: marker(owner));
        if (camera || ids.length == widget.request.limit - 1) {
          final file = await picker.pickImage(
            source: camera ? ImageSource.camera : ImageSource.gallery,
            requestFullMetadata: false,
          );
          files = [?file];
        } else {
          files = await picker.pickMultiImage(
            limit: widget.request.limit - ids.length,
            requestFullMetadata: false,
          );
        }
      }
      if (!mounted || widget.api.owner != owner) return;
      if (await _storage.read(key: _pickerSlot) == marker(owner)) {
        await _storage.delete(key: _pickerSlot);
      }
      if (files.length > widget.request.limit - ids.length) {
        setState(() => message = '写真は合わせて${widget.request.limit}枚まで追加できます。');
        return;
      }
      final known = <String>{};
      for (final source in files) {
        if (!mounted || widget.api.owner != owner) break;
        try {
          final id = await jobs.add(draft, source, ids, knownHashes: known);
          if (!mounted || widget.api.owner != owner) break;
          if (id == null) {
            setState(() => message = '同じ写真は一度だけ追加できます。');
            continue;
          }
          staged.add(id);
          setState(() => ids.add(id));
        } catch (_) {
          if (mounted) {
            setState(() => message = '読み込めない写真があります。サイズや形式をご確認ください。');
          }
        }
      }
    } on PlatformException {
      if (mounted) {
        setState(() => message = '写真またはカメラを利用できません。設定で許可をご確認のうえ、もう一度お試しください。');
      }
    } catch (_) {
      if (mounted) setState(() => message = '写真を追加できませんでした。');
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  void _close({required bool commit}) {
    if (processing) return;
    final removed = commit ? staged.where((id) => !ids.contains(id)) : staged;
    for (final id in removed) {
      unawaited(jobs.discard(draft, id).catchError((Object _) {}));
    }
    committed = commit;
    staged.clear();
    Navigator.of(context).pop(commit ? ids : null);
  }

  @override
  void dispose() {
    if (!committed && widget.api.owner != null) {
      for (final id in staged) {
        unawaited(jobs.discard(draft, id).catchError((Object _) {}));
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !processing,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('写真を選択'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'キャンセル',
          onPressed: processing ? null : () => _close(commit: false),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Space.edge),
          children: [
            Text(
              'デバイス　選択（${ids.length}/${widget.request.limit}）',
              style: TypeStyles.heading,
            ),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                OutlinedButton(
                  onPressed: processing || ids.length >= widget.request.limit
                      ? null
                      : choose,
                  child: const Text('写真を選択'),
                ),
                OutlinedButton(
                  onPressed: processing || ids.length >= widget.request.limit
                      ? null
                      : () => choose(camera: true),
                  child: const Text('カメラで撮影'),
                ),
                if (Platform.isAndroid)
                  TextButton(
                    onPressed: processing ? null : () => choose(recover: true),
                    child: const Text('前回の選択を確認'),
                  ),
              ],
            ),
            if (widget.request.kind == 'post')
              TextButton(
                onPressed: processing || ids.length >= widget.request.limit
                    ? null
                    : () async {
                        final owner = widget.api.owner;
                        final photo = await selectCollectionPhoto(
                          context,
                          widget.api,
                          ids,
                        );
                        if (mounted &&
                            owner == widget.api.owner &&
                            photo != null &&
                            !ids.contains(photo) &&
                            ids.length < widget.request.limit) {
                          setState(() => ids.add(photo));
                        }
                      },
                child: const Text('コレクション'),
              ),
            if (processing)
              const LinearProgressIndicator(semanticsLabel: '写真を処理中'),
            if (message case final text?)
              Semantics(liveRegion: true, child: Text(text)),
            const SizedBox(height: Space.gap),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: ids.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemBuilder: (context, index) {
                final id = ids[index];
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isRemotePhoto(id) && widget.request.postId != null)
                      RemotePhoto(
                        widget.api,
                        PhotoPointer(
                          widget.request.kind,
                          widget.request.postId!,
                          id,
                        ),
                        fit: BoxFit.cover,
                      )
                    else if (isRemotePhoto(id))
                      const Center(
                        child: Icon(
                          Icons.collections_outlined,
                          semanticLabel: 'コレクションの写真',
                        ),
                      )
                    else
                      LocalPhotoPreview(jobs, draft, id),
                    Align(
                      alignment: Alignment.topLeft,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(color: Colors.black54),
                        child: Text(
                          ' ${index + 1} ',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            for (final (index, id) in ids.indexed)
              ListTile(
                title: Text('写真 ${index + 1}'),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: '前に移動',
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: processing || index == 0
                          ? null
                          : () {
                              setState(() {
                                ids.removeAt(index);
                                ids.insert(index - 1, id);
                              });
                            },
                    ),
                    IconButton(
                      tooltip: '次に移動',
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: processing || index == ids.length - 1
                          ? null
                          : () {
                              setState(() {
                                ids.removeAt(index);
                                ids.insert(index + 1, id);
                              });
                            },
                    ),
                    IconButton(
                      tooltip: '写真を外す',
                      icon: const Icon(Icons.close),
                      onPressed: processing
                          ? null
                          : () => setState(() => ids.removeAt(index)),
                    ),
                  ],
                ),
              ),
            FilledButton(
              onPressed: processing ? null : () => _close(commit: true),
              child: const Text('完了'),
            ),
          ],
        ),
      ),
    ),
  );
}

class LocalPhotoPreview extends StatefulWidget {
  const LocalPhotoPreview(this.jobs, this.draft, this.id, {super.key});
  final PhotoJobs jobs;
  final String draft, id;

  @override
  State<LocalPhotoPreview> createState() => _LocalPhotoPreviewState();
}

class _LocalPhotoPreviewState extends State<LocalPhotoPreview> {
  late Future<PhotoJob?> value = widget.jobs.local(widget.draft, widget.id);
  @override
  void didUpdateWidget(LocalPhotoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.id != oldWidget.id || widget.draft != oldWidget.draft) {
      value = widget.jobs.local(widget.draft, widget.id);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PhotoJob?>(
    future: value,
    builder: (context, snapshot) {
      final photo = snapshot.data?.photo;
      if (photo == null) {
        return const ColoredBox(
          color: Palette.surface,
          child: Icon(Icons.image_outlined),
        );
      }
      return LocalPhoto(photo.thumb, decodeWidth: 320);
    },
  );
}
