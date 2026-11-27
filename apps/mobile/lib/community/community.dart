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
  final favoritesUpdates = ValueNotifier(0);
  final recentUpdates = ValueNotifier(0);
  final photoMemory = PhotoMemory();
  bool get hasPhotos => account.gateway is PhotoGateway;
  String? get owner => account.memberId;

  Future<Json> read(String path, [Map<String, String> params = const {}]) {
    final endpoint = Uri(
      path: path,
      queryParameters: params.isEmpty ? null : params,
    ).toString();
    return _reads.putIfAbsent(endpoint, () {
      late final Future<Json> pending;
      pending = account.community(endpoint).whenComplete(() {
        if (identical(_reads[endpoint], pending)) _reads.remove(endpoint);
      });
      return pending;
    });
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
    if (_closed || path == '/v1/reports') return value;
    if (path.startsWith('/v1/favorites/')) {
      _reads.removeWhere(
        (key, _) =>
            key.startsWith('/v1/favorites') ||
            key.startsWith('/v1/posts?category=favorites') ||
            key.startsWith('/v1/tags/popular') ||
            key.startsWith('/v1/members/official'),
      );
      favoritesUpdates.value++;
    } else if (path == '/v1/me/recents' || path.startsWith('/v1/me/recents/')) {
      _reads.removeWhere((key, _) => key.startsWith('/v1/me/recents'));
      recentUpdates.value++;
    } else {
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
    favoritesUpdates.dispose();
    recentUpdates.dispose();
    photoMemory.clear();
    _reads.clear();
    super.dispose();
  }
}
