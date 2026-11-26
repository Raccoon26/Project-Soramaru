import 'dart:io';
import 'dart:ui' as ui;

import 'package:bootstrap/community/comments.dart';
import 'package:bootstrap/community/community.dart';
import 'package:bootstrap/community/drafts.dart';
import 'package:bootstrap/community/reactions.dart';
import 'package:bootstrap/membership/controller.dart';
import 'package:bootstrap/membership/gateway.dart';
import 'package:bootstrap/navigation/deep_links.dart';
import 'package:bootstrap/navigation/destinations.dart';
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

const postId = '06800000-0000-4000-8000-000000000021';
const commentId = '06800000-0000-4000-8000-000000000022';
const replyId = '06800000-0000-4000-8000-000000000023';
const captureKey = ValueKey('dev07-capture');
const stamp = {
  'id': 'thanks',
  'label': 'ありがとう',
  'description': 'ハートと「ありがとう」',
  'icon': 'heart',
  'setId': 'greetings',
  'setLabel': '開発用あいさつ',
};

class InteractionFixture extends Fixture {
  final submitted = <Json>[];
  final reactions = <String>[];
  bool rejectReaction = false;
  bool liked = false;
  Json row(String id, {bool reply = false}) => {
    'id': id,
    'authorId': reply ? 'another-member' : 'demo-member',
    'postId': postId,
    'body': reply ? '合成の返信です。' : '今日は空がきれいです。',
    'nickname': reply ? '海の会員' : '空の会員',
    'createdAt': 0,
    'updatedAt': 0,
    'version': 1,
    'removed': false,
    'commentCount': reply ? 0 : 1,
    'likes': 0,
    'liked': false,
    'parentId': reply ? commentId : null,
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
    if (path == '/v1/stamps') {
      return {
        'items': [
          stamp,
          for (final (id, label, icon) in [
            ('hello', 'おはよう', 'sun'),
            ('tea', 'おつかれさま', 'tea'),
            ('cheers', 'おめでとう', 'party'),
            ('great', 'いいね！', 'spark'),
            ('night', 'おやすみ', 'moon'),
            ('happy', 'うれしい', 'flower'),
            ('later', 'またね', 'wave'),
          ])
            {
              ...stamp,
              'id': id,
              'label': label,
              'description': label,
              'icon': icon,
            },
        ],
      };
    }
    if (path.startsWith('/v1/reactions/')) {
      reactions.add(method);
      if (rejectReaction) throw const MembershipFailure('unavailable', 503);
      liked = method == 'PUT';
      return {'liked': liked, 'likes': liked ? 1 : 0};
    }
    if (path == '/v1/me/activity') {
      return {
        'items': [
          {
            'id': 'comment:$commentId',
            'postId': postId,
            'commentId': commentId,
            'kind': 'comment',
            'createdAt': 0,
            'body': '活動のプレビュー',
          },
        ],
        'nextCursor': null,
      };
    }
    if (path == '/v1/comments/$commentId') return row(commentId);
    if (path == '/v1/comments/$replyId') return row(replyId, reply: true);
    if (path.startsWith('/v1/posts/$postId/comments')) {
      if (method == 'POST') {
        if (body == null || headers['idempotency-key'] == null) {
          throw const MembershipFailure('invalid_request', 400);
        }
        submitted.add(body);
        return row(commentId);
      }
      return {
        'items': [
          if (path.contains('parent='))
            row(replyId, reply: true)
          else
            row(commentId),
        ],
        'nextCursor': null,
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

Future<
  (
    InteractionFixture,
    MembershipController,
    DraftRepository,
    NavigationController,
  )
>
make() async {
  final fixture = InteractionFixture();
  final account = MembershipController(fixture, Vault());
  await account.signIn(mailbox, samplePassword);
  final drafts = DraftRepository(
    DraftDatabase(NativeDatabase.memory()),
    Keys(),
  );
  final nav = NavigationController(
    session: () => const DemoSession(),
    resources: const SampleResources(),
    now: DateTime.now,
    generation: 0,
    community: Community(account, drafts),
  );
  return (fixture, account, drafts, nav);
}

Future<void> capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = Directory('../../.local/dev-07-preview');
    await out.create(recursive: true);
    await File('${out.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test('UUID comment ingress preserves target while sample links keep their routes', () {
    const deep = DeepLinks(SampleResources(), community: true);
    final link = deep.parse('soramaru-dev://open/comment/$replyId');
    expect(link?.screen, Screen.comments);
    expect(link?.comment, replyId);
    expect(link?.location, endsWith('?comment=$replyId'));
    expect(deep.parse('soramaru-dev://open/comment/$replyId#other'), isNull);
  });

  testWidgets(
    'stamp selection is explicit, replies open and response is submitted once',
    (tester) async {
      configureView(tester, const Size(390, 840));
      final (fixture, account, drafts, nav) = await make();
      const previews = bool.fromEnvironment('DEV07_PREVIEW');
      if (previews) {
        await tester.runAsync(() async {
          final font = FontLoader('Dev07 JP')
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
            theme: soramaruTheme(fontFamily: previews ? 'Dev07 JP' : null),
            home: RepaintBoundary(
              key: captureKey,
              child: Scaffold(body: child),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(CommentBoard(nav, postId));
      expect(find.text('今日は空がきれいです。'), findsOneWidget);
      if (previews) await capture(tester, '01-comments');
      await tester.tap(find.text('返信 1 件'));
      await tester.pumpAndSettle();
      expect(find.text('合成の返信です。'), findsOneWidget);
      if (previews) await capture(tester, '02-replies');
      await tester.tap(find.byTooltip('スタンプ'));
      await tester.pumpAndSettle();
      if (previews) await capture(tester, '03-stamps');
      await tester.tap(find.text('ありがとう'));
      await tester.pumpAndSettle();
      expect(fixture.submitted, isEmpty);
      await tester.tap(find.text('送信'));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(fixture.submitted.single['stampId'], 'thanks');
      await show(ForumActivity(nav));
      expect(find.text('活動のプレビュー'), findsOneWidget);
      if (previews) await capture(tester, '04-activity');
      await tester.pumpWidget(const SizedBox.shrink());
      nav.dispose();
      account.dispose();
      await tester.runAsync(drafts.close);
    },
  );

  testWidgets(
    'likes coalesce quick taps and roll back after a failed mutation',
    (tester) async {
      final (fixture, account, drafts, nav) = await make();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReactionButton(nav.community!, 'comment', commentId, const {
              'likes': 0,
              'liked': false,
            }),
          ),
        ),
      );
      await tester.tap(find.byType(TextButton));
      await tester.tap(find.byType(TextButton));
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.reactions, isEmpty);
      await tester.tap(find.byType(TextButton));
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.reactions, ['PUT']);
      expect(find.text('1'), findsOneWidget);
      fixture.rejectReaction = true;
      await tester.tap(find.byType(TextButton));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(fixture.reactions, ['PUT', 'DELETE']);
      expect(find.text('1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      nav.dispose();
      account.dispose();
      await tester.runAsync(drafts.close);
    },
  );

  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('comments and stamp panel fit ${width.toInt()}dp at $scale', (
        tester,
      ) async {
        configureView(tester, Size(width, 780), scale: scale);
        final (_, account, drafts, nav) = await make();
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: CommentBoard(nav, postId))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('スタンプ'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('ありがとう'), findsOneWidget);
        await tester.tap(find.byTooltip('キーボード'));
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        nav.dispose();
        account.dispose();
        await tester.runAsync(drafts.close);
      });
    }
  }
}
