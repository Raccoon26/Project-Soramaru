import 'dart:async';
import 'dart:io';

import 'package:bootstrap/network/api_client.dart';
import 'package:bootstrap/network/api_notice.dart';
import 'package:bootstrap/ui/feedback.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class ScriptTransport implements ApiTransport {
  ScriptTransport(this.replies);
  final List<FutureOr<ApiReply> Function()> replies;
  final List<(Uri, String?)> calls = [];
  bool closed = false;

  @override
  Future<ApiReply> get(Uri uri, {String? token}) async {
    calls.add((uri, token));
    return replies.removeAt(0)();
  }

  @override
  void close() => closed = true;
}

ApiClient client(ScriptTransport transport, {TokenSource? token}) => ApiClient(
  Uri.parse('https://example.invalid'),
  transport: transport,
  tokenSource: token,
  retryDelay: Duration.zero,
);

TypeMatcher<ApiFailure> issue(ApiIssue type) =>
    isA<ApiFailure>().having((failure) => failure.issue, 'issue', type);

void main() {
  test(
    'public readiness decodes a typed response without credentials',
    () async {
      final transport = ScriptTransport([
        () => const ApiReply(200, '{"status":"ready"}'),
      ]);
      final api = client(
        transport,
        token: () async => throw StateError('unexpected'),
      );
      expect(await api.readiness(), isTrue);
      expect(transport.calls.single, (
        Uri.parse('https://example.invalid/v1/ready'),
        null,
      ));
      api.close();
      expect(transport.closed, isTrue);
    },
  );

  test(
    'protected endpoint requires supplied credentials and never falls back',
    () async {
      final transport = ScriptTransport([
        () =>
            const ApiReply(401, '{"error":{"code":"authentication_required"}}'),
      ]);
      await expectLater(
        client(transport).sessionRole(),
        throwsA(issue(ApiIssue.signIn)),
      );
      expect(transport.calls, isEmpty);
      final api = client(transport, token: () async => 'fixture-offline-token');
      await expectLater(api.sessionRole(), throwsA(issue(ApiIssue.signIn)));
      expect(transport.calls.single.$2, 'fixture-offline-token');
    },
  );

  test('authority and redirect errors fail closed', () async {
    final transport = ScriptTransport([() => const ApiReply(302, '')]);
    for (final url in [
      'http://example.invalid',
      'https://user@example.invalid',
      'https://example.invalid/path',
      'https://example.invalid?override=localhost',
      'file:///local/',
    ]) {
      expect(
        () => ApiClient(Uri.parse(url), transport: transport),
        throwsArgumentError,
      );
    }
    await expectLater(
      client(transport).readiness(),
      throwsA(issue(ApiIssue.invalidResponse)),
    );
    expect(transport.calls, hasLength(1));
  });

  test('stale scopes neither return results nor retry', () async {
    final older = Completer<ApiReply>();
    final transport = ScriptTransport([
      () => older.future,
      () => const ApiReply(200, '{"status":"ready"}'),
    ]);
    final api = client(transport);
    final scope = ApiScope();
    final previous = api.readiness(scope: scope);
    final assertion = expectLater(previous, throwsA(issue(ApiIssue.cancelled)));
    expect(await api.readiness(scope: scope), isTrue);
    older.complete(const ApiReply(504, ''));
    await assertion;
    expect(transport.calls, hasLength(2));
  });

  test(
    'only safe reads retry once for connection or gateway failures',
    () async {
      final transport = ScriptTransport([
        () => throw const SocketException('fixture disconnected'),
        () => const ApiReply(200, '{"status":"ready"}'),
        () => const ApiReply(502, ''),
        () => const ApiReply(504, ''),
      ]);
      final api = client(transport);
      expect(await api.readiness(), isTrue);
      await expectLater(api.readiness(), throwsA(issue(ApiIssue.unavailable)));
      expect(transport.calls, hasLength(4));
    },
  );

  test(
    'timeout retries are bounded and late completions are ignored',
    () async {
      final first = Completer<ApiReply>();
      final second = Completer<ApiReply>();
      final transport = ScriptTransport([
        () => first.future,
        () => second.future,
      ]);
      final api = ApiClient(
        Uri.parse('https://example.invalid'),
        transport: transport,
        timeout: const Duration(milliseconds: 10),
        retryDelay: Duration.zero,
      );
      await expectLater(api.readiness(), throwsA(issue(ApiIssue.network)));
      first.complete(const ApiReply(200, '{"status":"ready"}'));
      second.complete(const ApiReply(200, '{"status":"ready"}'));
      expect(transport.calls, hasLength(2));
    },
  );

  test(
    'Japanese shared notice mapping honors 429 and 503 without retries',
    () async {
      for (final (status, code, expected, notice) in [
        (403, 'access_denied', ApiIssue.forbidden, ViewState.forbidden),
        (429, 'rate_limited', ApiIssue.rateLimited, ViewState.rateLimited),
        (503, 'maintenance', ApiIssue.maintenance, ViewState.maintenance),
        (503, 'cost_limited', ApiIssue.budget, ViewState.budget),
      ]) {
        final transport = ScriptTransport([
          () => ApiReply(
            status,
            '{"error":{"code":"$code"}}',
            retryAfter: '7',
            requestId: 'untrusted header',
          ),
        ]);
        await expectLater(
          client(transport).readiness(),
          throwsA(
            issue(expected)
                .having(
                  (failure) => failure.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 7),
                )
                .having((failure) => failure.requestId, 'requestId', isNull),
          ),
        );
        expect(noticeFor(expected), notice);
        expect(transport.calls, hasLength(1));
      }
    },
  );

  testWidgets(
    'developer panel surfaces the shared cost notice on explicit request',
    (tester) async {
      final transport = ScriptTransport([
        () => const ApiReply(503, '{"error":{"code":"cost_limited"}}'),
      ]);
      final api = client(transport);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [devApiProvider.overrideWithValue(api)],
          child: const MaterialApp(home: Scaffold(body: DevApiPanel())),
        ),
      );
      expect(transport.calls, isEmpty);
      await tester.tap(find.text('開発用サーバーの接続を確認'));
      await tester.pumpAndSettle();
      expect(find.byType(StateNotice), findsOneWidget);
      expect(
        tester.widget<StateNotice>(find.byType(StateNotice)).status,
        ViewState.budget,
      );
    },
  );
}
