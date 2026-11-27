import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bootstrap/community/collections.dart';
import 'package:bootstrap/community/community.dart';
import 'package:bootstrap/community/discovery.dart';
import 'package:bootstrap/community/drafts.dart';
import 'package:bootstrap/community/tag_picker.dart';
import 'package:bootstrap/membership/controller.dart';
import 'package:bootstrap/membership/gateway.dart';
import 'package:bootstrap/navigation/navigation_app.dart';
import 'package:bootstrap/navigation/sample_data.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:bootstrap/ui/design.dart';
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'membership_test.dart' show Fixture, Vault, mailbox, samplePassword;
import 'support.dart';

const testId = '06800000-0000-4000-8000-000000000071';
const albumId = '06800000-0000-4000-8000-000000000072';
const folderId = '06800000-0000-4000-8000-000000000073';
const captureKey = ValueKey('dev08-capture');

class DiscoveryFixture extends Fixture {
  int queries = 0;
  final writes = <String>[];
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
    if (uri.path == '/v1/search') {
      queries++;
      return {
        'items': [
          {'id': testId, 'label': '春の記録　カタカナ'},
        ],
      };
    }
    if (uri.path == '/v1/tags/popular') {
      return {
        'items': [
          {'id': testId, 'label': '朝の散歩', 'saved': false},
        ],
        'capturedAt': 1795578000000,
      };
    }
    if (uri.path == '/v1/members/official') {
      return {
        'items': [
          {'id': testId, 'label': '合成アーティスト'},
        ],
      };
    }
    if (uri.path == '/v1/favorites') {
      return {
        'items': [
          {'id': testId, 'label': 'お気に入りの項目'},
        ],
      };
    }
    if (uri.path.startsWith('/v1/favorites/')) {
      if (method != 'GET') writes.add('$method ${uri.path}');
      return {'saved': method == 'PUT'};
    }
    if (uri.path == '/v1/collections') {
      return {
        'items': [
          {'id': folderId, 'title': '春のしおり', 'version': 1},
        ],
      };
    }
    if (uri.path == '/v1/collections/$folderId') {
      return {
        'items': [
          {'id': testId, 'albumId': albumId, 'label': '合成アルバム'},
        ],
      };
    }
    if (uri.path == '/v1/me/blocks') {
      return {
        'items': [
          {'id': testId, 'label': '合成のユーザー', 'created': 1795578000000},
        ],
      };
    }
    if (uri.path == '/v1/me/recents') {
      return {
        'items': [
          {'id': albumId, 'label': '合成アルバム', 'created': 1795578000000},
        ],
      };
    }
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

Future<void> snapshot(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('../../.local/dev-08-preview');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test('Japanese compatibility normalization preserves the underlying search intent', () {
    expect(normalizeSearch(' ＣＡＦＥ　ｶﾞｸ  한글🇯🇵 '), 'cafe がく 한글🇯🇵');
    expect(tagKey('#Ｃａｆｅ'), 'cafe');
    expect(tagKey('カ\u3099'), 'ガ');
  });

  test('encrypted search history deduplicates normalized queries and purges only the affected member', () async {
    final path = await Directory.systemTemp.createTemp('discovery-history-');
    final file = File('${path.path}/model.sqlite');
    final keys = Keys();
    var repository = DraftRepository(DraftDatabase(NativeDatabase(file)), keys);
    try {
      await repository.rememberSearch(
        'account-one',
        'post',
        '会員の検索カタカナ',
        '会員の検索かたかな',
      );
      await repository.rememberSearch(
        'account-one',
        'post',
        '会員の検索ｶﾀｶﾅ',
        '会員の検索かたかな',
      );
      await repository.rememberSearch('account-two', 'tag', '独立記録', '独立記録');
      await repository.close();
      final stored = latin1.decode(await file.readAsBytes());
      expect(stored, isNot(contains(latin1.decode(utf8.encode('独立記録')))));
      repository = DraftRepository(DraftDatabase(NativeDatabase(file)), keys);
      expect(await repository.searchHistory('account-one'), hasLength(1));
      expect(await repository.searchHistory('account-two'), hasLength(1));
      expect(await repository.searchHistory('account-three'), isEmpty);
      await repository.purge('account-one');
      expect(await repository.searchHistory('account-one'), isEmpty);
      final current = (await repository.searchHistory('account-two')).single;
      await repository.removeSearch('account-two', current.id);
      expect(await repository.searchHistory('account-two'), isEmpty);
    } finally {
      await repository.close();
      await path.delete(recursive: true);
    }
  });

  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('discovery screens lay out at $width and $scale', (
        tester,
      ) async {
        configureView(tester, Size(width, 840), scale: scale);
        final fixture = DiscoveryFixture();
        final account = MembershipController(fixture, Vault());
        await account.signIn(mailbox, samplePassword);
        final drafts = DraftRepository(
          DraftDatabase(NativeDatabase.memory()),
          Keys(),
        );
        final api = Community(account, drafts);
        final nav = NavigationController(
          session: () => const DemoSession(),
          resources: const SampleResources(),
          now: DateTime.now,
          generation: 0,
          community: api,
        );
        const enabled = bool.fromEnvironment('DEV08_PREVIEW');
        final capture = enabled && width == 390 && scale == 1;
        if (capture) {
          await tester.runAsync(() async {
            final font = FontLoader('Dev08 JP')
              ..addFont(
                File('../../.local/downloads/NotoSansJP.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              );
            await font.load();
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
          });
        }
        Future<void> show(Widget child) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: soramaruTheme(fontFamily: capture ? 'Dev08 JP' : null),
              home: RepaintBoundary(
                key: captureKey,
                child: Scaffold(body: child),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        await show(SearchPage(nav));
        await tester.enterText(find.byType(TextField), 'ｶﾀｶﾅ');
        await tester.pump(const Duration(milliseconds: 500));
        expect(fixture.queries, 0);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('春の記録　カタカナ'), findsOneWidget);
        if (capture) await snapshot(tester, '01-search');
        await show(FavoriteList(nav));
        expect(find.text('お気に入りの項目'), findsOneWidget);
        if (capture) await snapshot(tester, '02-favorites');
        await show(FolderList(nav));
        expect(find.text('春のしおり'), findsOneWidget);
        if (capture) await snapshot(tester, '03-folders');
        await show(FolderContents(nav, folderId));
        expect(find.text('合成アルバム'), findsOneWidget);
        await show(RecentAlbums(nav));
        expect(find.text('合成アルバム'), findsOneWidget);
        if (capture) await snapshot(tester, '04-recents');
        await show(managedBlocks(nav));
        expect(find.text('合成のユーザー'), findsOneWidget);
        if (capture) await snapshot(tester, '05-blocks');
        await show(TagPicker(api, ['空']));
        expect(find.text('選択（1/10）'), findsOneWidget);
        if (capture) await snapshot(tester, '06-tag-picker');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(drafts.close);
        nav.dispose();
        account.dispose();
      });
    }
  }
}
