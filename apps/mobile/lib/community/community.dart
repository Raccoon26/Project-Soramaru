import 'package:flutter/foundation.dart';

import '../membership/controller.dart';
import '../membership/gateway.dart';
import '../photos/photo_view.dart';
import 'drafts.dart';

class Community extends ChangeNotifier {
  Community(this.account, this.drafts);
  final MembershipController account;
  final DraftRepository drafts;
  final Map<String, Future<Json>> _reads = {};
  bool _closed = false;
  final Map<String, DateTime> _albumVisits = {};
  int revision = 0;
  final photoMemory = PhotoMemory();
  bool get hasPhotos => account.gateway is PhotoGateway;
  String? get owner => account.memberId;

  Future<Json> read(String path, [Map<String, String> params = const {}]) {
    final endpoint = Uri(
      path: path,
      queryParameters: params.isEmpty ? null : params,
    ).toString();
    final generation = revision;
    return _reads.putIfAbsent(
      endpoint,
      () => account.community(endpoint).whenComplete(() {
        if (revision == generation) _reads.remove(endpoint);
      }),
    );
  }

  Future<void> recordAlbum(String id) async {
    final now = DateTime.now();
    final previous = _albumVisits[id];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 5)) {
      return;
    }
    _albumVisits[id] = now;
    if (_albumVisits.length > 100) _albumVisits.remove(_albumVisits.keys.first);
    try {
      await write('/v1/me/recents/$id', 'PUT');
    } catch (_) {
      if (_albumVisits[id] == now) _albumVisits.remove(id);
    }
  }

  Future<Json> write(
    String path,
    String method, {
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    final value = await account.community(
      path,
      method: method,
      body: body,
      headers: headers,
    );
    if (method == 'DELETE' && path == '/v1/me/recents') _albumVisits.clear();
    if (method == 'DELETE' && path.startsWith('/v1/me/recents/')) {
      _albumVisits.remove(path.split('/').last);
    }
    if (!_closed &&
        path != '/v1/reports' &&
        path != '/v1/me/recents' &&
        !path.startsWith('/v1/me/recents/')) {
      revision++;
      photoMemory.clear();
      _reads.clear();
      notifyListeners();
    }
    return value;
  }

  @override
  void dispose() {
    _closed = true;
    _albumVisits.clear();
    photoMemory.clear();
    _reads.clear();
    super.dispose();
  }
}
