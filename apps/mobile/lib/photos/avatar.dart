import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../community/community.dart';
import '../membership/gateway.dart';
import '../network/api_client.dart';
import 'photo_jobs.dart';
import 'photo_view.dart';
import 'processing.dart';

class AvatarPicker extends StatefulWidget {
  const AvatarPicker(
    this.api,
    this.original, {
    required this.onChanged,
    required this.onBusy,
    this.enabled = true,
    super.key,
  });
  final Community api;
  final String? original;
  final ValueChanged<String?> onChanged;
  final ValueChanged<bool> onBusy;
  final bool enabled;

  @override
  State<AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<AvatarPicker> {
  Uint8List? preview;
  PhotoJob? pending;
  TransferCancel? transfer;
  double? progress;
  String? error;
  bool busy = false, removed = false;

  Future<void> _choose() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('写真を選択'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              title: const Text('カメラで撮影'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    await _replace(source: source);
  }

  Future<void> _replace({ImageSource? source}) async {
    final cancel = TransferCancel();
    final owner = widget.api.owner;
    setState(() {
      busy = true;
      error = null;
      transfer = cancel;
      progress = null;
    });
    widget.onBusy(true);
    try {
      if (source != null) {
        await const FlutterSecureStorage().delete(
          key: 'soramaru.active-photo-picker.v1',
        );
        final file = await PhotoJobs.picker().pickImage(
          source: source,
          requestFullMetadata: false,
        );
        if (file == null) return;
        pending = PhotoJob(await processPicked(file, avatar: true));
      }
      if (!mounted ||
          cancel.cancelled ||
          widget.api.owner != owner ||
          pending == null) {
        return;
      }
      final id = await PhotoJobs(widget.api)
          .upload(pending!, 'avatar', cancel, (value) {
            if (mounted) setState(() => progress = value);
          });
      if (!mounted || cancel.cancelled || widget.api.owner != owner) return;
      setState(() {
        preview = pending!.photo.full;
        pending = null;
        removed = false;
      });
      widget.onChanged(id);
    } on PlatformException {
      if (mounted) setState(() => error = '写真またはカメラの利用許可を設定でご確認ください。');
    } on MembershipFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '画像を変更できませんでした。サイズや形式をご確認ください。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
          transfer = null;
        });
        widget.onBusy(false);
      }
    }
  }

  @override
  void dispose() {
    transfer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.api.owner;
    final picture = preview;
    final original = widget.original;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          height: 96,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: picture != null
                ? LocalPhoto(picture, decodeWidth: 256)
                : !removed && owner != null && original != null
                ? RemotePhoto(
                    widget.api,
                    PhotoPointer('profile', owner, original),
                    fit: BoxFit.cover,
                  )
                : const ColoredBox(
                    color: Colors.black12,
                    child: Icon(Icons.person_outline),
                  ),
          ),
        ),
        if (busy)
          LinearProgressIndicator(
            value: progress,
            semanticsLabel: '写真をアップロード中',
          ),
        if (error case final problem?)
          Semantics(liveRegion: true, child: Text(problem)),
        Wrap(
          children: [
            TextButton(
              onPressed: !widget.enabled || busy ? null : _choose,
              child: const Text('プロフィール画像を変更'),
            ),
            if (pending != null && !busy)
              TextButton(onPressed: _replace, child: const Text('再試行')),
            if (busy)
              TextButton(
                onPressed: () => transfer?.cancel(),
                child: const Text('アップロードを中止'),
              ),
            if (!busy && (picture != null || original != null && !removed))
              TextButton(
                onPressed: widget.enabled
                    ? () {
                        setState(() {
                          removed = true;
                          preview = null;
                          pending = null;
                          error = null;
                        });
                        widget.onChanged(null);
                      }
                    : null,
                child: const Text('画像を削除'),
              ),
          ],
        ),
      ],
    );
  }
}
