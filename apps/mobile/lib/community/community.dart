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
    if (!_closed && path != '/v1/reports') {
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
    photoMemory.clear();
    _reads.clear();
    super.dispose();
  }
}
