import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bootstrap/community/composer.dart';
import 'package:bootstrap/community/drafts.dart';
import 'package:bootstrap/membership/controller.dart';
import 'package:bootstrap/membership/gateway.dart';
import 'package:bootstrap/navigation/navigation_app.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'membership_test.dart'
    show Fixture, Vault, mailbox, samplePassword, tapVisible;

import 'support.dart';

const owner = '06800000-0000-4000-8000-000000000011';
const entry = '06800000-0000-4000-8000-000000000012';
const captureKey = ValueKey('forum-preview');

class Keys implements DraftKeys {
  final values = <String, String>{};
  @override
  Future<String?> read(String owner) async => values[owner];
  @override
  Future<void> write(String owner, String key) async => values[owner] = key;
  @override
  Future<void> remove(String owner) async => values.remove(owner);
}

class ForumFixture extends Fixture {
  final posts = <Json>[];
  final submitted = <String>[];
  bool failWrite = false;

  @override
  Future<Json> api(
    String path, {
    String method = 'GET',
    String? idToken,
    String? appSession,
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(path);
    if (uri.path == '/v1/posts' && method == 'GET') {
      return {'items': posts, 'pinned': [], 'nextCursor': null};
    }
    if (uri.path == '/v1/posts' && method == 'POST') {
      submitted.add(headers['idempotency-key']!);
      if (failWrite) throw const MembershipFailure('unavailable');
      final row = <String, Object?>{
        'id': entry,
        'body': body!['body'],
        'tags': <Json>[],
        'nickname': '青いノート',
        'authorId': owner,
        'category': 'member',
        'pinned': false,
        'createdAt': 1800000000000,
        'updatedAt': 1800000000000,
        'version': 1,
        'quoteId': null,
      };
      if (posts.isEmpty) posts.add(row);
      return row;
    }
    if (uri.path == '/v1/posts/$entry') return posts.single;
    if (uri.path == '/v1/tags/popular') return {'items': []};
    return super.api(
      path,
      method: method,
      idToken: idToken,
      appSession: appSession,
      body: body,
      headers: headers,
    );
  }
}

void main() {
  test('Unicode 16 corpus matches server boundaries', () {
    const patterns = ['か\u3099', '👨‍👩‍👧‍👦', '🇯🇵', '👍🏽', '한'];
    final five = patterns.join();
    final full = List.filled(2000, five).join();
    expect(postLength(full), 10000);
    expect(postLength('あ' * 9999), 9999);
    expect(postLength('幅$full'), 10001);
    expect(postLength('a\r\nＡ\rｶ'), 5);
    expect(utf8.encode(full).length, greaterThan(16384));
  });

  test('encrypted SQLite v2 separates accounts, survives DB reopen and erases drafts', () async {
    final directory = await Directory.systemTemp.createTemp('drafts-test-');
    final file = File('${directory.path}/draft.sqlite');
    final keys = Keys();
    var repository = DraftRepository(DraftDatabase(NativeDatabase(file)), keys);
    try {
      final first = Draft(
        id: 'one',
        started: 5,
        updated: 7,
        body: 'private draft fixture',
        tags: ['空'],
        quoteId: entry,
        postId: entry,
        version: 2,
        requestKey: 'fixture-key',
      );
      final second = Draft(
        id: 'two',
        started: 6,
        updated: 9,
        body: 'second draft fixture',
      );
      await repository.save(owner, first);
      await repository.save(owner, second);
      await repository.save(entry, first);
      await repository.close();
      expect(
        latin1.decode(await file.readAsBytes()),
        isNot(contains('private draft fixture')),
      );
      repository = DraftRepository(DraftDatabase(NativeDatabase(file)), keys);
      final recovered = await repository.list(owner);
      expect(recovered.map((draft) => draft.id), ['two', 'one']);
      expect(recovered.last.toJson(), first.toJson());
      await repository.remove(owner, 'two');
      expect(await repository.list(owner), hasLength(1));
      await repository.purge(owner);
      expect(await repository.list(owner), isEmpty);
      expect(await repository.list(entry), hasLength(1));
    } finally {
      await repository.close();
      await directory.delete(recursive: true);
    }
  });

  test('session failure purges only that member while ordinary signout retains drafts', () async {
    final gateway = ForumFixture();
    gateway.profile['id'] = owner;
    final repository = DraftRepository(
      DraftDatabase(NativeDatabase.memory()),
      Keys(),
    );
    final account = MembershipController(
      gateway,
      Vault(),
      purgeDrafts: repository.purge,
    );
    try {
      final draft = Draft.fresh();
      await repository.save(owner, draft);
      await repository.save(entry, draft);
      await account.signIn(mailbox, samplePassword);
      await account.signOut();
      expect(await repository.list(owner), hasLength(1));
      await account.signIn(mailbox, samplePassword);
      await account.clear(MemberPhase.expired);
      expect(await repository.list(owner), isEmpty);
      expect(await repository.list(entry), hasLength(1));
    } finally {
      account.dispose();
      await repository.close();
    }
  });

  test(
    'Drift v1 upgrade keeps the draft table and enables timestamps',
    () async {
      final database = DraftDatabase(
        NativeDatabase.memory(
          setup: (db) {
            db.execute(
              'CREATE TABLE drafts(owner TEXT NOT NULL,id TEXT NOT NULL,blob TEXT NOT NULL,PRIMARY KEY(owner,id))',
            );
            db.execute(
              "INSERT INTO drafts VALUES ('fixture-owner','fixture-id','opaque-fixture')",
            );
            db.execute('PRAGMA user_version=1');
          },
        ),
      );
      try {
        final row = await database
            .customSelect('SELECT id,updated,blob FROM drafts')
            .getSingle();
        expect(row.read<String>('id'), 'fixture-id');
        expect(row.read<int>('updated'), 0);
        expect(row.read<String>('blob'), 'opaque-fixture');
      } finally {
        await database.close();
      }
    },
  );

  const capture = bool.fromEnvironment('DEV05_CAPTURE');
  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('forum composer width $width at $scale', (tester) async {
        configureView(tester, Size(width, 820), scale: scale);
        final gateway = ForumFixture();
        gateway.profile['id'] = owner;
        final repository = DraftRepository(
          DraftDatabase(NativeDatabase.memory()),
          Keys(),
        );
        final account = MembershipController(gateway, Vault());
        final writeScreenshot = capture && width == 390 && scale == 1;
        if (writeScreenshot) {
          gateway.posts.add({
            'id': entry,
            'body': '春の風が気持ちいい朝です。',
            'nickname': '青いノート',
            'authorId': entry,
            'category': 'member',
            'pinned': false,
            'tags': [
              {'id': entry, 'label': '朝の便り'},
            ],
            'quoteId': null,
            'createdAt': 1800000000000,
            'updatedAt': 1800000000000,
            'version': 1,
          });
        }
        if (writeScreenshot) {
          await tester.runAsync(() async {
            for (final (family, path) in [
              ('Dev05 JP', '../../.local/downloads/NotoSansJP.ttf'),
              (
                'MaterialIcons',
                '../../.local/sdk/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
              ),
            ]) {
              final bytes = await File(path).readAsBytes();
              final font = FontLoader(family)
                ..addFont(Future.value(ByteData.sublistView(bytes)));
              await font.load();
            }
          });
        }
        await account.restore();
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: ProviderScope(
              overrides: [
                membershipProvider.overrideWithValue(account),
                demoSessionProvider.overrideWith(
                  () => EmulatorIdentity(account),
                ),
                draftRepositoryProvider.overrideWithValue(repository),
              ],
              child: NavigationApp(
                fontFamily: writeScreenshot ? 'Dev05 JP' : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), mailbox);
        await tester.enterText(fields.at(1), samplePassword);
        await tapVisible(tester, 'ログイン');
        expect(find.text('ALL'), findsOneWidget);
        Future<void> takePreview(String name) async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1.5);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('../../.local/dev-05-preview');
            await directory.create(recursive: true);
            await File('${directory.path}/$name.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        if (writeScreenshot) {
          await takePreview('01-feed');
          await tapVisible(tester, '春の風が気持ちいい朝です。');
          await takePreview('02-detail');
          await tester.tap(find.byIcon(Icons.more_horiz).first);
          await tester.pumpAndSettle();
          await tapVisible(tester, '投稿を報告');
          await takePreview('04-report');
          await tapVisible(tester, 'キャンセル');
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        await tapVisible(tester, '投稿する');
        await tester.pumpAndSettle();
        expect(find.text('記事を作成'), findsOneWidget);
        final body = find.byType(TextField).first;
        await tester.enterText(
          body,
          width == 320 && scale == 2 ? 'あ' * 10000 : '朝の便り\n晴れました。🍵',
        );
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        if (writeScreenshot) await takePreview('03-compose');
        await tester.pumpWidget(const SizedBox.shrink());
        account.dispose();
        await tester.runAsync(repository.close);
      });
    }
  }
}
