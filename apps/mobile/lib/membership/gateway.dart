import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../network/api_client.dart';

typedef Json = Map<String, Object?>;

class MembershipFailure implements Exception {
  const MembershipFailure(this.code, [this.status = 0]);
  final String code;
  final int status;

  String get message => switch (code) {
    'invalid_credentials' => 'メールアドレスまたはパスワードをご確認ください。',
    'invalid_code' => 'コードが無効か、有効期限が切れています。',
    'authentication_required' => 'ログインの有効期限が切れました。',
    'recent_auth_required' => '安全のため、もう一度ログインしてからお試しください。',
    'email_unverified' => 'メールアドレスの確認が必要です。',
    'account_suspended' => 'このアカウントの利用は停止されています。',
    'account_deleting' => 'アカウントの削除手続き中です。',
    'rate_limited' => '時間をおいてからもう一度お試しください。',
    'cost_limited' => '現在、利用できる機能を制限しています。',
    'maintenance' => 'ただいまメンテナンス中です。',
    'policy_changed' => '最新の規約をご確認ください。',
    'invalid_post_length' => '本文は10,000文字までです。複雑な文字は短くしてください。',
    'content_rejected' => '投稿できない文字やリンクが含まれています。本文をご確認ください。',
    'not_found' => 'この投稿またはプロフィールは表示できません。',
    'payload_too_large' => '入力されたデータが大きすぎます。',
    'nickname_reserved' => 'この表示名は使用できません。',
    'device_limit' => '登録できる端末数の上限に達しています。',
    'conflict' => '内容が更新されました。読み込み直してからお試しください。',
    'invalid_request' => '入力内容をご確認ください。',
    'access_denied' => 'この操作を行う権限がありません。',
    _ => '接続できませんでした。時間をおいてお試しください。',
  };
}

MembershipFailure firebaseFailure(
  String code,
  int status, {
  bool signingIn = false,
}) {
  if (status == 429 || code == 'TOO_MANY_ATTEMPTS_TRY_LATER') {
    return MembershipFailure('rate_limited', status);
  }
  if (status >= 500) return MembershipFailure('unavailable', status);
  if (signingIn) return MembershipFailure('invalid_credentials', status);
  return MembershipFailure(switch (code) {
    'INVALID_OOB_CODE' || 'EXPIRED_OOB_CODE' => 'invalid_code',
    'USER_DISABLED' => 'account_suspended',
    'TOKEN_EXPIRED' ||
    'INVALID_REFRESH_TOKEN' ||
    'USER_NOT_FOUND' ||
    'INVALID_GRANT' => 'authentication_required',
    _ => 'invalid_credentials',
  }, status);
}

class FirebaseTokens {
  const FirebaseTokens(this.idToken, this.refreshToken, this.expiresAt);
  final String idToken;
  final String refreshToken;
  final DateTime expiresAt;

  factory FirebaseTokens.from(Json body, {bool refreshed = false}) {
    final id = body[refreshed ? 'id_token' : 'idToken'];
    final refresh = body[refreshed ? 'refresh_token' : 'refreshToken'];
    final seconds = int.tryParse(
      (body[refreshed ? 'expires_in' : 'expiresIn'] ?? '').toString(),
    );
    if (id is! String ||
        refresh is! String ||
        seconds == null ||
        seconds < 1 ||
        seconds > 7200) {
      throw const MembershipFailure('unavailable');
    }
    return FirebaseTokens(
      id,
      refresh,
      DateTime.now().add(Duration(seconds: seconds)),
    );
  }
}

abstract interface class MembershipGateway {
  Future<FirebaseTokens> signIn(
    String email,
    String password, {
    bool signup = false,
  });
  Future<FirebaseTokens> refresh(String token);
  Future<void> verifyCode(String code);
  Future<void> changeEmail(String token, String email);
  Future<void> resetCode(String code, {String? password});
  Future<Json> api(
    String path, {
    String method = 'GET',
    String? idToken,
    String? appSession,
    Json? body,
    Map<String, String> headers = const {},
  });
  void dispose();
}

abstract interface class PhotoGateway {
  Future<Uint8List> photoBytes(
    String path, {
    required String token,
    required String session,
    Uint8List? upload,
    TransferCancel? cancel,
    void Function(double)? progress,
  });
}

class LoopbackMembership implements MembershipGateway, PhotoGateway {
  LoopbackMembership(String host)
    : _worker = Uri(scheme: 'http', host: host, port: 8787),
      _firebase = Uri(scheme: 'http', host: host, port: 9099) {
    if (!kDebugMode ||
        !const {'localhost', '127.0.0.1', '10.0.2.2', '::1'}.contains(host)) {
      throw ArgumentError('Local debug membership origin required');
    }
  }

  final Uri _worker;
  final Uri _firebase;
  final _transport = IoApiTransport(const Duration(seconds: 8));

  Future<Json> _send(
    Uri uri,
    String method, {
    Json? body,
    String? token,
    Map<String, String> headers = const {},
    String? form,
    bool provider = false,
  }) async {
    ApiReply response;
    try {
      response = await _transport.send(
        uri,
        method,
        token: token,
        headers: headers,
        body: body,
        form: form,
        maxReplyBytes: uri.path.startsWith('/v1/posts') ? 730000 : 65536,
      );
    } on IOException {
      throw const MembershipFailure('unavailable');
    } on TimeoutException {
      throw const MembershipFailure('unavailable');
    } on ApiFailure {
      throw const MembershipFailure('unavailable');
    }
    if (response.status == 204) return const {};
    final Object? parsed;
    try {
      parsed = jsonDecode(response.body);
    } on FormatException {
      throw const MembershipFailure('unavailable');
    }
    if (parsed is! Json) throw const MembershipFailure('unavailable');
    if (response.status >= 200 && response.status < 300) return parsed;
    if (provider) {
      final error = parsed['error'];
      final msg = error is Json ? error['message'] : null;
      final key = msg is String ? msg.split(' ').first : '';
      throw firebaseFailure(
        key,
        response.status,
        signingIn: uri.path.endsWith(':signInWithPassword'),
      );
    }
    final error = parsed['error'];
    final code = error is Json ? error['code'] : null;
    throw MembershipFailure(
      code is String ? code : 'unavailable',
      response.status,
    );
  }

  Future<Json> _identity(String action, Json payload) => _send(
    _firebase.replace(
      path: '/identitytoolkit.googleapis.com/v1/accounts:$action',
      queryParameters: {'key': 'demo-local-key'},
    ),
    'POST',
    body: payload,
    provider: true,
  );

  @override
  Future<FirebaseTokens> signIn(
    String email,
    String password, {
    bool signup = false,
  }) async => FirebaseTokens.from(
    await _identity(signup ? 'signUp' : 'signInWithPassword', {
      'email': email,
      'password': password,
      'returnSecureToken': true,
    }),
  );

  @override
  Future<FirebaseTokens> refresh(String token) async => FirebaseTokens.from(
    await _send(
      _firebase.replace(
        path: '/securetoken.googleapis.com/v1/token',
        queryParameters: {'key': 'demo-local-key'},
      ),
      'POST',
      provider: true,
      form:
          'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(token)}',
    ),
    refreshed: true,
  );

  @override
  Future<void> verifyCode(String code) async {
    await _identity('update', {'oobCode': code});
  }

  @override
  Future<void> changeEmail(String token, String email) async {
    await _identity('update', {
      'idToken': token,
      'email': email,
      'returnSecureToken': false,
    });
  }

  @override
  Future<void> resetCode(String code, {String? password}) async {
    await _identity('resetPassword', {
      'oobCode': code,
      'newPassword': ?password,
    });
  }

  @override
  Future<Json> api(
    String path, {
    String method = 'GET',
    String? idToken,
    String? appSession,
    Json? body,
    Map<String, String> headers = const {},
  }) {
    final target = Uri.parse(path);
    if (target.hasAuthority ||
        target.hasScheme ||
        target.hasFragment ||
        !RegExp(
          r'^/v1/(?:auth/(?:policies|email)|me(?:/session|/terms)?|sessions(?:/renew|/[0-9a-f-]{36})?|posts(?:/[0-9a-f-]{36})?|members/[0-9a-f-]{36}|tags/popular|reports|uploads(?:/[0-9a-f-]{36}(?:/complete)?)?|gallery(?:/[0-9a-f-]{36})?|media/grants|me/blocks/[0-9a-f-]{36})$',
        ).hasMatch(target.path) ||
        (target.hasQuery &&
            !{'/v1/posts', '/v1/gallery'}.contains(target.path))) {
      throw ArgumentError('Unknown membership API path');
    }
    return _send(
      _worker.replace(
        path: target.path,
        query: target.hasQuery ? target.query : null,
      ),
      method,
      body: body,
      token: idToken,
      headers: {...headers, 'x-app-session': ?appSession},
    );
  }

  @override
  Future<Uint8List> photoBytes(
    String path, {
    required String token,
    required String session,
    Uint8List? upload,
    TransferCancel? cancel,
    void Function(double)? progress,
  }) async {
    final uri = Uri.parse(path);
    final matcher = upload == null
        ? r'^/v1/media/[0-9a-f-]{36}$'
        : r'^/v1/uploads/[0-9a-f-]{36}/body$';
    if (uri.hasAuthority ||
        uri.hasScheme ||
        uri.hasFragment ||
        !RegExp(matcher).hasMatch(uri.path) ||
        (upload != null && (uri.hasQuery || upload.length > 800000))) {
      throw const MembershipFailure('invalid_request', 400);
    }
    final ByteReply response;
    try {
      response = await _transport.binary(
        _worker.replace(path: uri.path, query: uri.hasQuery ? uri.query : null),
        upload == null ? 'GET' : 'PUT',
        token: token,
        headers: {'x-app-session': session},
        upload: upload,
        cancel: cancel,
        progress: progress,
      );
    } on Object {
      if (cancel?.cancelled == true) throw const MembershipFailure('cancelled');
      throw const MembershipFailure('unavailable');
    }
    if (response.status >= 200 && response.status < 300) return response.body;
    String code = 'unavailable';
    try {
      final value = jsonDecode(utf8.decode(response.body)) as Json;
      code = (value['error'] as Json)['code'] as String;
    } catch (_) {}
    throw MembershipFailure(code, response.status);
  }

  @override
  void dispose() => _transport.close();
}
