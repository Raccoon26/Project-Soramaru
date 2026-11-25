import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../navigation/session.dart';
import 'gateway.dart';

enum MemberPhase {
  starting,
  signedOut,
  unverified,
  terms,
  profile,
  active,
  expired,
  suspended,
  deleting,
  offline,
}

abstract interface class CredentialVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> erase();
}

class OSVault implements CredentialVault {
  static const _key = 'soramaru.local.membership.v1';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  Future<File> _installMarker() async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}${Platform.pathSeparator}membership-install-v1');
  }

  @override
  Future<String?> read() async {
    final marker = await _installMarker();
    if (!await marker.exists()) {
      await erase();
      await marker.writeAsString('1', flush: true);
      return null;
    }
    return _storage.read(key: _key);
  }

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> erase() => _storage.delete(key: _key);
}

final membershipProvider = Provider<MembershipController?>((ref) => null);
const deviceAlias = 'スマートフォン';

class MembershipController extends ChangeNotifier {
  MembershipController(
    this.gateway,
    this.vault, {
    this.purgeDrafts,
    this.hasDrafts,
  });
  final MembershipGateway gateway;
  final CredentialVault vault;
  final Future<void> Function(String)? purgeDrafts;
  final Future<bool> Function(String)? hasDrafts;
  String? _owner;
  String? get memberId => profile?['id'] as String?;
  MemberPhase phase = MemberPhase.starting;
  Json? snapshot;
  FirebaseTokens? _tokens;
  String? _session;
  String? _refreshSecret;
  String? _nonce;
  Future<String>? _refreshing;
  int _refreshEpoch = -1;
  var _epoch = 0;
  var _closed = false;
  Future<void> _storageQueue = Future.value();
  final Map<String, Json> _devices = {};

  Json? get profile => snapshot?['profile'] as Json?;
  String? get sessionId => (snapshot?['session'] as Json?)?['id'] as String?;

  String _random() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _requireEpoch(int epoch) {
    if (_closed || _epoch != epoch) throw const MembershipFailure('cancelled');
  }

  Future<void> _persist(int epoch) {
    final data = jsonEncode({
      'refresh': _refreshSecret,
      'session': _session,
      'owner': _owner,
    });
    _storageQueue = _storageQueue.catchError((Object _) {}).then((_) {
      _requireEpoch(epoch);
      return vault.write(data);
    });
    return _storageQueue;
  }

  void _assign(Json response) {
    snapshot = response;
    _owner = memberId ?? _owner;
    phase = switch (response['phase']) {
      'unverified' => MemberPhase.unverified,
      'terms_required' => MemberPhase.terms,
      'profile_required' => MemberPhase.profile,
      'active' => MemberPhase.active,
      _ => throw const MembershipFailure('unavailable'),
    };
    _notify();
  }

  Future<String> _token({bool force = false}) {
    final current = _tokens;
    if (!force &&
        current != null &&
        current.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 2)),
        )) {
      return Future.value(current.idToken);
    }
    final epoch = _epoch;
    if (_refreshing != null && _refreshEpoch == epoch) return _refreshing!;
    _refreshEpoch = epoch;
    return _refreshing = _renewToken(epoch).whenComplete(() {
      if (_refreshEpoch == epoch) _refreshing = null;
    });
  }

  Future<String> _renewToken(int epoch) async {
    final fallback = _refreshSecret;
    if (fallback == null) {
      throw const MembershipFailure('authentication_required', 401);
    }
    final updated = await gateway.refresh(fallback);
    _requireEpoch(epoch);
    _tokens = updated;
    _refreshSecret = updated.refreshToken;
    if (_session != null) await _persist(epoch);
    return updated.idToken;
  }

  Future<void> restore() async {
    final epoch = _epoch;
    try {
      if (_refreshSecret == null) {
        final stored = await vault.read();
        _requireEpoch(epoch);
        if (stored == null) {
          phase = MemberPhase.signedOut;
          _notify();
          return;
        }
        final parsed = jsonDecode(stored);
        if (parsed is! Json ||
            parsed['refresh'] is! String ||
            parsed['session'] is! String) {
          await clear(MemberPhase.expired);
          return;
        }
        _refreshSecret = parsed['refresh'] as String;
        _session = parsed['session'] as String;
        _owner = parsed['owner'] as String?;
      }
      await refreshStatus();
    } on FormatException {
      if (epoch == _epoch) await clear(MemberPhase.expired);
    } on MembershipFailure catch (error) {
      if (epoch != _epoch) return;
      if (error.status == 401 || error.code == 'authentication_required') {
        await clear(MemberPhase.expired);
      } else if (error.code == 'account_suspended' ||
          error.code == 'account_deleting') {
        await clear(
          error.code == 'account_suspended'
              ? MemberPhase.suspended
              : MemberPhase.deleting,
        );
      } else {
        phase = MemberPhase.offline;
        snapshot = null;
        _notify();
      }
    } on Exception {
      if (epoch == _epoch) {
        phase = MemberPhase.offline;
        _notify();
      }
    }
  }

  Future<void> signIn(
    String email,
    String password, {
    bool signup = false,
  }) async {
    final epoch = ++_epoch;
    _nonce = _random();
    _owner = null;
    _session = null;
    snapshot = null;
    _tokens = null;
    _refreshSecret = null;
    _devices.clear();
    await _erase();
    final tokens = await gateway.signIn(email, password, signup: signup);
    _requireEpoch(epoch);
    _tokens = tokens;
    _refreshSecret = tokens.refreshToken;
    await finishSignIn();
  }

  Future<void> finishSignIn() async {
    final epoch = _epoch;
    final idToken = await _token();
    _requireEpoch(epoch);
    final issued = await gateway.api(
      '/v1/sessions',
      method: 'POST',
      idToken: idToken,
      headers: {'idempotency-key': _nonce ??= _random()},
      body: {
        'alias': deviceAlias,
        'os': Platform.isAndroid
            ? 'android'
            : Platform.isIOS
            ? 'ios'
            : 'other',
      },
    );
    _requireEpoch(epoch);
    final session = issued['sessionToken'];
    if (session is! String) throw const MembershipFailure('unavailable');
    _session = session;
    _owner = (issued['profile'] as Json?)?['id'] as String?;
    await _persist(epoch);
    _assign(Map<String, Object?>.of(issued)..remove('sessionToken'));
  }

  Future<Json> community(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
  }) {
    if (phase != MemberPhase.active) {
      throw const MembershipFailure('authentication_required');
    }
    return _call(path, method: method, body: body, headers: headers);
  }

  Future<bool> hasPendingDrafts() async {
    final owner = memberId;
    return owner != null &&
        await (hasDrafts?.call(owner) ?? Future.value(false));
  }

  Future<Json> _call(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    final epoch = _epoch;
    try {
      final token = await _token();
      _requireEpoch(epoch);
      final response = await gateway.api(
        path,
        method: method,
        idToken: token,
        appSession: _session,
        body: body,
        headers: headers,
      );
      _requireEpoch(epoch);
      return response;
    } on MembershipFailure catch (error) {
      if (epoch == _epoch) {
        if (error.code == 'authentication_required') {
          await clear(MemberPhase.expired);
        }
        if (error.code == 'account_suspended') {
          await clear(MemberPhase.suspended);
        }
        if (error.code == 'account_deleting') await clear(MemberPhase.deleting);
      }
      rethrow;
    }
  }

  Future<void> refreshStatus({bool force = false}) async {
    if (force) await _token(force: true);
    final value = await _call('/v1/me/session');
    final session = value['session'];
    final expires = session is Json ? session['expiresAt'] : null;
    if (expires is int &&
        expires - DateTime.now().millisecondsSinceEpoch < 900000) {
      _assign(await _call('/v1/sessions/renew', method: 'POST'));
    } else {
      _assign(value);
    }
  }

  Future<void> sendVerification() async {
    await _call('/v1/auth/email', method: 'POST', body: {'kind': 'verify'});
  }

  Future<void> verifyEmail(String? code) async {
    if (code != null && code.isNotEmpty) await gateway.verifyCode(code);
    await refreshStatus(force: true);
  }

  Future<void> changeEmail(String email) async {
    await gateway.changeEmail(await _token(), email);
    await clear();
  }

  Future<void> sendReset(String email) async {
    await gateway.api(
      '/v1/auth/email',
      method: 'POST',
      body: {'kind': 'reset', 'email': email},
    );
  }

  Future<void> resetPassword(String code, {String? password}) async {
    await gateway.resetCode(code, password: password);
  }

  Future<Json> policies() => gateway.api('/v1/auth/policies');

  Future<void> accept(String version) async {
    _assign(
      await _call(
        '/v1/me/terms',
        method: 'POST',
        body: {
          'version': version,
          'documents': ['terms', 'privacy', 'guidelines'],
        },
      ),
    );
  }

  Future<void> edit(Json body, int version) async {
    _assign(
      await _call(
        '/v1/me',
        method: 'PATCH',
        body: body,
        headers: {'if-match': '"$version"'},
      ),
    );
  }

  Future<List<String>> listDevices() async {
    final response = await _call('/v1/sessions');
    final items = response['items'];
    if (items is! List) throw const MembershipFailure('unavailable');
    _devices.clear();
    for (final item in items.whereType<Json>()) {
      _devices['device-${_devices.length + 1}'] = item;
    }
    return _devices.keys.toList(growable: false);
  }

  Json? device(String alias) => _devices[alias];

  Future<Json> deviceDetail(String alias) async {
    final id = _devices[alias]?['id'];
    if (id is! String) throw const MembershipFailure('access_denied');
    return _call('/v1/sessions/$id');
  }

  Future<void> revokeDevice(String alias) async {
    final id = _devices[alias]?['id'];
    if (id is! String) throw const MembershipFailure('access_denied');
    await _call('/v1/sessions/$id', method: 'DELETE');
    _devices.remove(alias);
    if (id == sessionId) await clear();
  }

  Future<void> signOut({bool all = false}) async {
    final id = sessionId;
    if (id != null && _session != null) {
      try {
        await _call(
          all ? '/v1/sessions' : '/v1/sessions/$id',
          method: 'DELETE',
        );
      } on MembershipFailure {
        if (all) rethrow;
      }
    }
    await clear();
  }

  Future<void> _erase() {
    _storageQueue = _storageQueue
        .catchError((Object _) {})
        .then((_) => vault.erase());
    return _storageQueue;
  }

  Future<void> clear([MemberPhase result = MemberPhase.signedOut]) async {
    _epoch++;
    final owner = _owner;
    _owner = null;
    _tokens = null;
    _session = null;
    _refreshSecret = null;
    _nonce = null;
    _devices.clear();
    snapshot = null;
    phase = result;
    _notify();
    try {
      await _erase();
    } finally {
      if (owner != null &&
          [
            MemberPhase.expired,
            MemberPhase.suspended,
            MemberPhase.deleting,
          ].contains(result)) {
        await purgeDrafts?.call(owner);
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _epoch++;
    gateway.dispose();
    super.dispose();
  }
}

class EmulatorIdentity extends DemoIdentity {
  EmulatorIdentity(this.controller);
  final MembershipController controller;

  @override
  DemoSession build() {
    void sync() {
      final update = _state();
      if (update.status != state.status ||
          update.account != state.account ||
          update.role != state.role) {
        change(update.status, role: update.role, account: update.account);
      }
    }

    controller.addListener(sync);
    ref.onDispose(() => controller.removeListener(sync));
    return _state();
  }

  DemoSession _state() {
    final status = switch (controller.phase) {
      MemberPhase.starting || MemberPhase.offline => SessionStatus.checking,
      MemberPhase.signedOut => SessionStatus.signedOut,
      MemberPhase.unverified => SessionStatus.unverified,
      MemberPhase.terms || MemberPhase.profile => SessionStatus.termsRequired,
      MemberPhase.active => SessionStatus.member,
      MemberPhase.expired => SessionStatus.expired,
      MemberPhase.suspended => SessionStatus.suspended,
      MemberPhase.deleting => SessionStatus.deleting,
    };
    return DemoSession(
      status: status,
      account: status == SessionStatus.member
          ? (controller.profile?['id'] as String?)
          : null,
      role: switch (controller.snapshot?['role']) {
        'artist' => MemberRole.artist,
        'administrator' => MemberRole.administrator,
        _ => MemberRole.member,
      },
    );
  }
}
