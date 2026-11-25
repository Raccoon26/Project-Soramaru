import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bootstrap/membership/controller.dart';
import 'package:bootstrap/membership/gateway.dart';
import 'package:bootstrap/membership/screens.dart';
import 'package:bootstrap/navigation/navigation_app.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:bootstrap/ui/design.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

const number = 'SM-SYNTHETIC';
const mailbox = 'fixture@example.invalid';
const samplePassword = 'Preview-only-phrase';
const photo = ValueKey('dev04-capture');

class RealLocalHttp extends HttpOverrides {}

class Vault implements CredentialVault {
  String? saved;
  @override
  Future<String?> read() async => saved;
  @override
  Future<void> write(String value) async {
    saved = value;
  }

  @override
  Future<void> erase() async {
    saved = null;
  }
}

class Fixture implements MembershipGateway {
  String phase = 'active';
  int refreshes = 0;
  bool offline = false;
  bool revoked = false;
  final calls = <String>[];
  Completer<FirebaseTokens>? blocker;

  static FirebaseTokens tokens() => FirebaseTokens(
    'provider-fixture',
    'refresh-fixture',
    DateTime.now().add(const Duration(hours: 1)),
  );

  Json profile = {
    'id': 'demo-member',
    'memberNumber': number,
    'joinedAt': 0,
    'nickname': '空の会員',
    'biography': '開発用サンプル',
    'birthMonth': null,
    'birthDay': null,
    'version': 1,
    'collectionPublic': false,
  };

  Json get context => {
    'phase': phase,
    'role': 'member',
    'policyVersion': 'fixture',
    'profile': profile,
    'session': {
      'id': '00000000-0000-4000-8000-000000000001',
      'expiresAt': DateTime.now()
          .add(const Duration(hours: 4))
          .millisecondsSinceEpoch,
    },
  };

  @override
  Future<Json> api(
    String path, {
    String method = 'GET',
    String? idToken,
    String? appSession,
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    calls.add('$method $path');
    if (offline) throw const MembershipFailure('unavailable', 503);
    if (revoked) throw const MembershipFailure('authentication_required', 401);
    if (path == '/v1/sessions' && method == 'POST') {
      return {...context, 'sessionToken': 'app-fixture'};
    }
    if (path == '/v1/me/terms') phase = 'profile_required';
    if (path == '/v1/me' && method == 'PATCH') {
      profile = {...profile, ...?body, 'version': 2};
      phase = 'active';
    }
    if (path == '/v1/auth/policies') {
      return {
        'version': 'fixture',
        'documents': [
          {'kind': 'terms', 'title': '利用規約', 'text': '開発用の規約です。'},
          {'kind': 'privacy', 'title': 'プライバシーポリシー', 'text': '開発用の案内です。'},
          {
            'kind': 'guidelines',
            'title': 'コミュニティガイドライン',
            'text': 'お互いを尊重してください。',
          },
        ],
      };
    }
    if (path == '/v1/sessions' && method == 'GET') {
      return {
        'items': [
          {
            'id': '00000000-0000-4000-8000-000000000001',
            'alias': 'スマートフォン',
            'status': 'active',
            'os': 'android',
            'current': true,
            'createdAt': 0,
            'lastSeen': 0,
          },
        ],
      };
    }
    return context;
  }

  @override
  Future<FirebaseTokens> signIn(
    String email,
    String password, {
    bool signup = false,
  }) async {
    if (signup) phase = 'unverified';
    return tokens();
  }

  @override
  Future<FirebaseTokens> refresh(String token) async {
    refreshes++;
    return blocker == null ? tokens() : blocker!.future;
  }

  @override
  Future<void> verifyCode(String code) async {
    phase = 'terms_required';
  }

  @override
  Future<void> changeEmail(String token, String email) async {}
  @override
  Future<void> resetCode(String code, {String? password}) async {}
  @override
  void dispose() {}
}

class LoggedPane extends StatelessWidget {
  const LoggedPane(this.controller, {this.fontFamily, super.key});
  final MembershipController controller;
  final String? fontFamily;
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: soramaruTheme(fontFamily: fontFamily),
    home: RepaintBoundary(
      key: photo,
      child: Scaffold(body: MembershipGate(controller, onCancel: () {})),
    ),
  );
}

Future<void> tapVisible(WidgetTester tester, String label) async {
  final item = find.text(label).last;
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'provider action-code expiry and sign-in enumeration have stable messages',
    () {
      expect(firebaseFailure('EXPIRED_OOB_CODE', 400).code, 'invalid_code');
      expect(
        firebaseFailure('INVALID_OOB_CODE', 400).message,
        firebaseFailure('EXPIRED_OOB_CODE', 400).message,
      );
      for (final reason in [
        'USER_NOT_FOUND',
        'EMAIL_NOT_FOUND',
        'INVALID_PASSWORD',
        'USER_DISABLED',
      ]) {
        expect(
          firebaseFailure(reason, 400, signingIn: true).code,
          'invalid_credentials',
        );
      }
    },
  );

  if (const bool.fromEnvironment('DEV04_LIVE')) {
    test('Dart gateway connects to the real local emulators', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final endpoint = Uri.parse(
          'http://127.0.0.1:9099/emulator/v1/projects/demo-soramaru-auth/oobCodes',
        );
        final gateway = LoopbackMembership('127.0.0.1');
        final client = HttpClient();
        final address =
            'flutter-${DateTime.now().microsecondsSinceEpoch}@example.invalid';
        final controller = MembershipController(gateway, Vault());
        try {
          await controller.signIn(address, samplePassword, signup: true);
          expect(controller.phase, MemberPhase.unverified);
          await controller.sendVerification();
          final response = await (await client.getUrl(endpoint)).close();
          final fixture =
              jsonDecode(await response.transform(utf8.decoder).join()) as Json;
          final codes = (fixture['oobCodes'] as List).whereType<Json>();
          final code =
              codes.firstWhere((item) => item['email'] == address)['oobCode']
                  as String;
          await controller.verifyEmail(code);
          expect(controller.phase, MemberPhase.terms);
          final copy = await controller.policies();
          await controller.accept(copy['version'] as String);
          await controller.edit({'nickname': '空の会員'}, 1);
          expect(controller.phase, MemberPhase.active);
          final limits = [9999, 10000, 10001];
          for (final limit in limits) {
            final body = 'か\u3099' * limit;
            final key =
                'flutter-community-${DateTime.now().microsecondsSinceEpoch}';
            final submission = controller.community(
              '/v1/posts',
              method: 'POST',
              headers: {'idempotency-key': key},
              body: {
                'body': body,
                'tags': ['朝'],
              },
            );
            if (limit == 10001) {
              await expectLater(submission, throwsA(isA<MembershipFailure>()));
            } else {
              expect((await submission)['body'], body);
            }
          }
          final feed = await controller.community('/v1/posts?limit=20');
          expect((feed['items'] as List), isNotEmpty);
          final devices = await controller.listDevices();
          expect(devices, hasLength(1));
          await controller.signOut();
          expect(controller.phase, MemberPhase.signedOut);
        } finally {
          client.close(force: true);
          controller.dispose();
        }
      }, RealLocalHttp());
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('startup restores two credentials once and transient outage does not erase the vault', () async {
    final gateway = Fixture();
    final vault = Vault()
      ..saved = jsonEncode({
        'refresh': 'refresh-fixture',
        'session': 'app-fixture',
      });
    final controller = MembershipController(gateway, vault);
    gateway.offline = true;
    await controller.restore();
    expect(controller.phase, MemberPhase.offline);
    expect(controller.profile, isNull);
    expect(vault.saved, isNotNull);
    gateway.offline = false;
    await controller.restore();
    expect(controller.phase, MemberPhase.active);
    expect(gateway.refreshes, 1);
    expect(gateway.calls.where((c) => c == 'GET /v1/me/session'), hasLength(2));
    gateway.revoked = true;
    await controller.restore();
    expect(controller.phase, MemberPhase.expired);
    expect(vault.saved, isNull);
    expect(controller.profile, isNull);
    controller.dispose();
  });

  test(
    'concurrent forced refresh coalesces and sign out fences a late response',
    () async {
      final gateway = Fixture(), vault = Vault();
      final controller = MembershipController(gateway, vault);
      await controller.signIn(mailbox, samplePassword);
      gateway.blocker = Completer<FirebaseTokens>();
      final old = controller.refreshStatus(force: true);
      final second = controller.refreshStatus(force: true);
      final firstError = expectLater(old, throwsA(isA<MembershipFailure>()));
      final secondError = expectLater(
        second,
        throwsA(isA<MembershipFailure>()),
      );
      expect(gateway.refreshes, 1);
      await controller.clear();
      gateway.blocker!.complete(Fixture.tokens());
      await Future.wait([firstError, secondError]);
      expect(controller.phase, MemberPhase.signedOut);
      expect(controller.profile, isNull);
      expect(vault.saved, isNull);
      controller.dispose();
    },
  );

  test(
    'verification, latest policies and profile setup progress in order',
    () async {
      final gateway = Fixture();
      final controller = MembershipController(gateway, Vault());
      await controller.signIn(mailbox, samplePassword, signup: true);
      expect(controller.phase, MemberPhase.unverified);
      await controller.verifyEmail('disposable-code');
      expect(controller.phase, MemberPhase.terms);
      await controller.accept('fixture');
      expect(controller.phase, MemberPhase.profile);
      await controller.edit({'nickname': '空 한 🐾 e\u0301'}, 1);
      expect(controller.phase, MemberPhase.active);
      expect(controller.profile?['nickname'], '空 한 🐾 e\u0301');
      controller.dispose();
    },
  );

  testWidgets(
    'A01 uses a pending deep link through login then returns to the target',
    (tester) async {
      final account = MembershipController(Fixture(), Vault());
      await account.restore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            membershipProvider.overrideWithValue(account),
            demoSessionProvider.overrideWith(() => EmulatorIdentity(account)),
            initialExternalLinkProvider.overrideWithValue(
              'soramaru-dev://open/post/post-1',
            ),
          ],
          child: const NavigationApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('パスワードをお忘れですか？'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), mailbox);
      await tester.enterText(fields.at(1), samplePassword);
      await tapVisible(tester, 'ログイン');
      expect(find.text('投稿詳細'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
    },
  );

  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('Japanese signup layout at ${width.toInt()} and $scale', (
        tester,
      ) async {
        configureView(tester, Size(width, 760), scale: scale);
        final account = MembershipController(Fixture(), Vault());
        await account.restore();
        await tester.pumpWidget(LoggedPane(account));
        await tester.pumpAndSettle();
        final mail = tester.widget<TextField>(find.byType(TextField).first);
        expect(mail.keyboardType, TextInputType.emailAddress);
        expect(mail.autofillHints, contains(AutofillHints.email));
        await tapVisible(tester, '新規会員登録');
        expect(find.byType(CheckboxListTile), findsWidgets);
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        account.dispose();
      });
    }
  }

  if (const bool.fromEnvironment('DEV04_CAPTURE')) {
    testWidgets('capture local membership views', (tester) async {
      configureView(tester, const Size(390, 820));
      await tester.runAsync(() async {
        Future<void> loadFont(String family, String path) async {
          final bytes = await File(path).readAsBytes();
          final loader = FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
        }

        await loadFont('Dev04 JP', '../../.local/downloads/NotoSansJP.ttf');
        await loadFont(
          'MaterialIcons',
          '../../.local/sdk/flutter/bin/cache/artifacts/material_fonts/'
              'materialicons-regular.otf',
        );
      });
      final gateway = Fixture();
      final account = MembershipController(gateway, Vault());
      await account.restore();
      await tester.pumpWidget(LoggedPane(account, fontFamily: 'Dev04 JP'));
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(photo),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('../../.local/dev-04-preview');
          await directory.create(recursive: true);
          await File('${directory.path}/$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('01-login');
      await tapVisible(tester, '新規会員登録');
      await capture('02-signup');
      await account.signIn(mailbox, samplePassword, signup: true);
      await tester.pumpAndSettle();
      await capture('03-email-verification');
      await account.verifyEmail('fixture-code');
      await tester.pumpAndSettle();
      await capture('04-terms');
      await account.accept('fixture');
      await tester.pumpAndSettle();
      await capture('05-profile-setup');
      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
    });
  }
}
