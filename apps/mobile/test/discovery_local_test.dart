import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bootstrap/membership/gateway.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

Future<Json> getEmulatorVerification(String email) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final response = await (await client.getUrl(
      Uri.parse(
        'http://127.0.0.1:9099/emulator/v1/projects/demo-soramaru-auth/oobCodes',
      ),
    )).close();
    expect(response.statusCode, 200);
    final body =
        jsonDecode(await response.transform(utf8.decoder).join()) as Json;
    return (body['oobCodes'] as List).cast<Json>().firstWhere(
      (row) => row['email'] == email && row['requestType'] == 'VERIFY_EMAIL',
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  test(
    'Flutter transport connects Auth, discovery, D1 and private R2',
    () async {
      final api = LoopbackMembership('127.0.0.1');
      final rng = Random.secure();
      String key() =>
          base64UrlEncode(List.generate(32, (_) => rng.nextInt(256)))
              .replaceAll('=', '');
      final email = 'flutter-${key().toLowerCase()}@example.invalid';
      final password = 'Synthetic-${key()}';
      try {
        var identity = await api.signIn(email, password, signup: true);
        await api.api(
          '/v1/auth/email',
          method: 'POST',
          idToken: identity.idToken,
          body: {'kind': 'verify'},
        );
        final verify = await getEmulatorVerification(email);
        await api.verifyCode(verify['oobCode'] as String);
        identity = await api.refresh(identity.refreshToken);
        final token = identity.idToken;
        final issue = await api.api(
          '/v1/sessions',
          method: 'POST',
          idToken: token,
          headers: {'idempotency-key': key()},
          body: {'alias': 'Synthetic Flutter Test', 'os': 'other'},
        );
        final session = issue['sessionToken'] as String;
        final policy = await api.api('/v1/auth/policies');
        Future<Json> call(
          String path, {
          String method = 'GET',
          Json? body,
          Map<String, String> headers = const {},
        }) => api.api(
          path,
          idToken: token,
          appSession: session,
          method: method,
          body: body,
          headers: headers,
        );
        await call(
          '/v1/me/terms',
          method: 'POST',
          body: {
            'version': policy['version'],
            'documents': (policy['documents'] as List)
                .cast<Json>()
                .map((value) => value['kind'])
                .toList(),
          },
        );
        await call(
          '/v1/me',
          method: 'PATCH',
          headers: {'if-match': '"1"'},
          body: {'nickname': '合成の読み手'},
        );
        final jpeg = image.Image(width: 96, height: 72);
        image.fill(jpeg, color: image.ColorRgb8(240, 170, 50));
        final bytes = Uint8List.fromList(image.encodeJpg(jpeg));
        final small = Uint8List.fromList(
          image.encodeJpg(image.copyResize(jpeg, width: 48)),
        );
        Future<String> store(
          String purpose,
          Uint8List bytes, {
          String? variant,
        }) async {
          final hash = await Sha256().hash(bytes);
          final sha = hash.bytes
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join();
          final created = await call(
            '/v1/uploads',
            method: 'POST',
            headers: {'idempotency-key': key()},
            body: {
              'purpose': purpose,
              'mime': 'image/jpeg',
              'bytes': bytes.length,
              'sha256': sha,
              'variantOf': ?variant,
            },
          );
          final media = created['id'] as String;
          await api.photoBytes(
            '/v1/uploads/$media/body',
            token: token,
            session: session,
            upload: bytes,
          );
          await call('/v1/uploads/$media/complete', method: 'POST');
          return media;
        }

        final media = await store('post', bytes);
        await store('thumbnail', small, variant: media);
        final text = 'フラッター春の記録 ${key()}';
        final post = await call(
          '/v1/posts',
          method: 'POST',
          headers: {'idempotency-key': key()},
          body: {
            'body': text,
            'tags': ['春'],
            'attachments': [media],
          },
        );
        final search = await call(
          Uri(
            path: '/v1/search',
            queryParameters: {'q': text.substring(0, 11), 'kind': 'post'},
          ).toString(),
        );
        expect(
          (search['items'] as List).cast<Json>().any(
            (item) => item['id'] == post['id'],
          ),
          isTrue,
        );
        final favor = await call(
          '/v1/favorites/post/${post['id']}',
          method: 'PUT',
        );
        expect(favor['saved'], isTrue);
        final photo = await api.photoBytes(
          '/v1/media/$media?parent=post&parent_id=${post['id']}&variant=full',
          token: token,
          session: session,
        );
        expect(photo, bytes);
        expect((await call('/v1/favorites?kind=post'))['items'], hasLength(1));
      } finally {
        api.dispose();
      }
    },
    skip: !const bool.fromEnvironment('DEV08_LOCAL'),
  );
}
