import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

enum ApiIssue {
  network,
  invalidResponse,
  signIn,
  forbidden,
  notFound,
  rateLimited,
  maintenance,
  budget,
  unavailable,
  cancelled,
}

class ApiFailure implements Exception {
  const ApiFailure(this.issue, {this.retryAfter, this.requestId});
  final ApiIssue issue;
  final Duration? retryAfter;
  final String? requestId;
}

typedef TokenSource = Future<String?> Function();

class ApiScope {
  int _generation = 0;

  void invalidate() => _generation++;
}

class ApiReply {
  const ApiReply(this.status, this.body, {this.retryAfter, this.requestId});
  final int status;
  final String body;
  final String? retryAfter;
  final String? requestId;
}

abstract interface class ApiTransport {
  Future<ApiReply> get(Uri uri, {String? token});
  void close();
}

class IoApiTransport implements ApiTransport {
  IoApiTransport(this.timeout)
    : _client = (HttpClient()..connectionTimeout = timeout);
  final Duration timeout;
  final HttpClient _client;

  @override
  Future<ApiReply> get(Uri uri, {String? token}) =>
      send(uri, 'GET', token: token);

  Future<ApiReply> send(
    Uri uri,
    String method, {
    String? token,
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    String? form,
    int maxReplyBytes = 65_536,
  }) async {
    HttpClientRequest? request;
    var timedOut = false;
    Future<ApiReply> operation() async {
      final outgoing = await _client.openUrl(method, uri);
      request = outgoing;
      if (timedOut) {
        outgoing.abort();
        throw TimeoutException('Request timed out');
      }
      outgoing.followRedirects = false;
      outgoing.headers.set('accept', 'application/json');
      if (token != null) outgoing.headers.set('authorization', 'Bearer $token');
      headers.forEach(outgoing.headers.set);
      if (body != null) {
        outgoing.headers.contentType = ContentType.json;
        outgoing.write(jsonEncode(body));
      } else if (form != null) {
        outgoing.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        outgoing.write(form);
      }
      final response = await outgoing.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxReplyBytes) {
          throw const ApiFailure(ApiIssue.invalidResponse);
        }
        bytes.add(chunk);
      }
      return ApiReply(
        response.statusCode,
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
        retryAfter: response.headers.value('retry-after'),
        requestId: response.headers.value('x-request-id'),
      );
    }

    return operation().timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        request?.abort();
        throw TimeoutException('Request timed out');
      },
    );
  }

  @override
  void close() => _client.close(force: true);
}

class ApiClient {
  ApiClient(
    Uri origin, {
    ApiTransport? transport,
    this.tokenSource,
    this.timeout = const Duration(seconds: 6),
    this.retryDelay = const Duration(milliseconds: 250),
  }) : _origin = _checkOrigin(origin),
       _transport = transport ?? IoApiTransport(timeout);

  final Uri _origin;
  final ApiTransport _transport;
  final TokenSource? tokenSource;
  final Duration timeout;
  final Duration retryDelay;
  bool _closed = false;

  static Uri _checkOrigin(Uri value) {
    const loopback = {'localhost', '127.0.0.1', '::1', '10.0.2.2'};
    final local =
        kDebugMode && value.scheme == 'http' && loopback.contains(value.host);
    if ((!local && value.scheme != 'https') ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        (value.path.isNotEmpty && value.path != '/')) {
      throw ArgumentError('Invalid API origin');
    }
    return value;
  }

  Future<bool> readiness({ApiScope? scope}) async {
    final payload = await _get('/v1/ready', scope: scope);
    if (payload['status'] != 'ready') {
      throw const ApiFailure(ApiIssue.invalidResponse);
    }
    return true;
  }

  Future<String> sessionRole({ApiScope? scope}) async {
    final payload = await _get('/v1/me/session', scope: scope, protected: true);
    final role = payload['role'];
    if (role is! String ||
        !const {'member', 'artist', 'administrator'}.contains(role)) {
      throw const ApiFailure(ApiIssue.invalidResponse);
    }
    return role;
  }

  Future<Map<String, Object?>> _get(
    String path, {
    ApiScope? scope,
    bool protected = false,
  }) async {
    final generation = scope == null ? null : ++scope._generation;
    void checkActive() {
      if (_closed || scope?._generation != generation) {
        throw const ApiFailure(ApiIssue.cancelled);
      }
    }

    checkActive();
    final token = protected ? await _readToken() : null;
    checkActive();
    if (protected && token == null) throw const ApiFailure(ApiIssue.signIn);

    for (var attempt = 0; attempt < 2; attempt++) {
      checkActive();
      try {
        final reply = await _transport
            .get(_origin.replace(path: path), token: token)
            .timeout(timeout);
        checkActive();
        if (attempt == 0 && (reply.status == 502 || reply.status == 504)) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        return _decode(reply);
      } on IOException {
        checkActive();
        if (attempt != 0) throw const ApiFailure(ApiIssue.network);
      } on TimeoutException {
        checkActive();
        if (attempt != 0) throw const ApiFailure(ApiIssue.network);
      }
      await Future<void>.delayed(retryDelay);
    }
    throw const ApiFailure(ApiIssue.network);
  }

  Future<String?> _readToken() async {
    try {
      final token = await tokenSource?.call().timeout(timeout);
      if (token != null &&
          RegExp(r'^[A-Za-z0-9._~-]{1,2048}$').hasMatch(token)) {
        return token;
      }
      return null;
    } on Exception {
      return null;
    }
  }

  Map<String, Object?> _decode(ApiReply reply) {
    Map<String, Object?>? json;
    try {
      final body = jsonDecode(reply.body);
      if (body is Map<String, Object?>) json = body;
    } on FormatException {
      // Proxies can replace JSON with an HTML error page.
    }
    if (reply.status == 200 && json != null) return json;

    final error = json?['error'];
    final code = error is Map<String, Object?> ? error['code'] : null;
    final issue = switch ((reply.status, code)) {
      (401, _) => ApiIssue.signIn,
      (403, _) => ApiIssue.forbidden,
      (404, _) => ApiIssue.notFound,
      (429, _) => ApiIssue.rateLimited,
      (503, 'maintenance') => ApiIssue.maintenance,
      (503, 'cost_limited') => ApiIssue.budget,
      (502 || 503 || 504, _) => ApiIssue.unavailable,
      _ => ApiIssue.invalidResponse,
    };
    final seconds = int.tryParse(reply.retryAfter ?? '');
    final id = reply.requestId;
    throw ApiFailure(
      issue,
      retryAfter: seconds != null && seconds > 0 && seconds <= 86400
          ? Duration(seconds: seconds)
          : null,
      requestId: id != null && RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)
          ? id
          : null,
    );
  }

  void close() {
    _closed = true;
    _transport.close();
  }
}
