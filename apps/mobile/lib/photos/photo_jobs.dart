import 'dart:convert';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../community/community.dart';
import '../community/drafts.dart';
import '../membership/gateway.dart';
import '../network/api_client.dart';
import 'processing.dart';

bool isRemotePhoto(String id) => RegExp(r'^[0-9a-f-]{36}$').hasMatch(id);

class PhotoJob {
  PhotoJob(
    this.photo, {
    String? fullKey,
    String? thumbKey,
    this.fullId,
    this.thumbId,
  }) : fullKey = fullKey ?? draftId(),
       thumbKey = thumbKey ?? draftId();

  final ProcessedPhoto photo;
  String fullKey, thumbKey;
  String? fullId, thumbId;

  factory PhotoJob.decode(Uint8List payload) {
    final data = jsonDecode(utf8.decode(payload)) as Json;
    return PhotoJob(
      ProcessedPhoto(
        base64Decode(data['full'] as String),
        base64Decode(data['thumb'] as String),
        data['hash'] as String,
        data['thumbHash'] as String,
        data['width'] as int,
        data['height'] as int,
      ),
      fullKey: data['fullKey'] as String,
      thumbKey: data['thumbKey'] as String,
      fullId: data['fullId'] as String?,
      thumbId: data['thumbId'] as String?,
    );
  }

  List<int> encode() => utf8.encode(
    jsonEncode({
      'full': base64Encode(photo.full),
      'thumb': base64Encode(photo.thumb),
      'hash': photo.hash,
      'thumbHash': photo.thumbHash,
      'width': photo.width,
      'height': photo.height,
      'fullKey': fullKey,
      'thumbKey': thumbKey,
      'fullId': fullId,
      'thumbId': thumbId,
    }),
  );
}

class PhotoJobs {
  const PhotoJobs(this.community);
  final Community community;

  bool get available => community.account.gateway is PhotoGateway;
  String get owner =>
      community.owner ??
      (throw const MembershipFailure('authentication_required'));
  DraftRepository get drafts => community.drafts;

  static ImagePicker picker() {
    final picker = ImagePickerPlatform.instance;
    if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
    return ImagePicker();
  }

  Future<PhotoJob?> local(String draft, String photo) async {
    final payload = await drafts.readPhoto(owner, draft, photo);
    return payload == null ? null : PhotoJob.decode(payload);
  }

  Future<String?> add(
    String draft,
    XFile file,
    Iterable<String> existing, {
    Set<String>? knownHashes,
  }) async {
    final account = owner;
    final result = await processPicked(file);
    if (community.owner != account) throw const MembershipFailure('cancelled');
    if (knownHashes?.contains(result.hash) == true) return null;
    for (final id in existing.where((id) => !isRemotePhoto(id))) {
      if ((await local(draft, id))?.photo.hash == result.hash) return null;
    }
    final id = draftId();
    if (community.owner != account) throw const MembershipFailure('cancelled');
    await drafts.storePhoto(account, draft, id, PhotoJob(result).encode());
    knownHashes?.add(result.hash);
    return id;
  }

  Future<void> discard(String draft, String id) async {
    if (isRemotePhoto(id)) return;
    final account = owner;
    final job = await local(draft, id);
    await drafts.removePhoto(account, draft, id);
    if (job != null && community.owner == account) {
      // If a draft is removed while offline the server recovers its grace-period uploads.
      for (final reservation in [job.fullId, job.thumbId].whereType<String>()) {
        try {
          await community.account.community(
            '/v1/uploads/$reservation',
            method: 'DELETE',
          );
        } on MembershipFailure {
          /* referenced bytes and unavailable cleanup remain server-owned */
        }
      }
    }
  }

  Future<String> uploadDraft(
    String draft,
    String localId,
    TransferCancel cancel,
    void Function(double) progress, {
    String purpose = 'post',
  }) async {
    if (isRemotePhoto(localId)) return localId;
    final account = owner;
    final job = await local(draft, localId) ?? (throw const PhotoProblem());
    Future<void> checkpoint() async {
      if (community.owner != account) {
        throw const MembershipFailure('cancelled');
      }
      await drafts.storePhoto(account, draft, localId, job.encode());
    }

    return upload(job, purpose, cancel, progress, checkpoint: checkpoint);
  }

  Future<String> upload(
    PhotoJob job,
    String purpose,
    TransferCancel cancel,
    void Function(double) progress, {
    Future<void> Function()? checkpoint,
  }) async {
    final account = owner;
    void active() {
      if (community.owner != account || cancel.cancelled) {
        throw const MembershipFailure('cancelled');
      }
    }

    Future<String> part({required bool thumb, String? root}) async {
      active();
      final bytes = thumb ? job.photo.thumb : job.photo.full;
      final hash = thumb ? job.photo.thumbHash : job.photo.hash;
      var key = thumb ? job.thumbKey : job.fullKey;
      final pendingId = thumb ? job.thumbId : job.fullId;

      Json? reservation;
      if (pendingId != null) {
        reservation = await community.account.community(
          '/v1/uploads/$pendingId',
        );
        if ([
              'expired',
              'cancelled',
              'deleted',
              'deleting',
            ].contains(reservation['state']) ||
            (['reserved', 'quarantined'].contains(reservation['state']) &&
                (reservation['expiresAt'] as int) <
                    DateTime.now().millisecondsSinceEpoch)) {
          reservation = null;
          key = draftId();
          if (thumb) {
            job.thumbKey = key;
            job.thumbId = null;
          } else {
            job.fullKey = key;
            job.fullId = null;
            job.thumbId = null;
            job.thumbKey = draftId();
          }
          await checkpoint?.call();
        }
      }
      Future<Json> reserve() => community.account.community(
        '/v1/uploads',
        method: 'POST',
        headers: {'idempotency-key': key},
        body: {
          'purpose': thumb ? 'thumbnail' : purpose,
          'bytes': bytes.length,
          'mime': 'image/jpeg',
          'sha256': hash,
          'variantOf': ?root,
        },
      );

      active();
      if (reservation == null) {
        try {
          reservation = await reserve();
        } on MembershipFailure catch (error) {
          if (error.status != 409 || pendingId != null) rethrow;
          // The prior request may have reserved an ID whose response was lost.
          // Restart only after the server rejects that key as a conflict.
          active();
          key = draftId();
          if (thumb) {
            job.thumbKey = key;
          } else {
            job.fullKey = key;
          }
          await checkpoint?.call();
          active();
          reservation = await reserve();
        }
      }
      final id = reservation['id'] as String;
      if (thumb) {
        job.thumbId = id;
      } else {
        job.fullId = id;
      }
      await checkpoint?.call();
      final span = purpose == 'avatar' ? 1.0 : (thumb ? .15 : .85);
      final offset = thumb ? .85 : 0.0;
      if (reservation['state'] == 'reserved') {
        active();
        await community.account.photoBytes(
          '/v1/uploads/$id/body',
          upload: bytes,
          cancel: cancel,
          progress: (fraction) => progress(offset + span * .9 * fraction),
        );
      }
      active();
      if (!['approved', 'attached'].contains(reservation['state'])) {
        final result = await community.account.community(
          '/v1/uploads/$id/complete',
          method: 'POST',
        );
        if (!['approved', 'attached'].contains(result['state'])) {
          throw const PhotoProblem();
        }
      }
      active();
      progress(offset + span);
      return id;
    }

    final root = await part(thumb: false);
    if (purpose != 'avatar') await part(thumb: true, root: root);
    return root;
  }
}
