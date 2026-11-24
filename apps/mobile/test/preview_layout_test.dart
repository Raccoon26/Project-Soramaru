import 'package:bootstrap/main.dart';
import 'package:bootstrap/ui/content.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:bootstrap/ui/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

const previewScreens = [
  ('fan-feed', '/', CommunityTab.feed, 'ファン投稿'),
  ('compose', '/compose', CommunityTab.feed, '記事を作成'),
  ('content-hub', '/', CommunityTab.content, 'コンテンツ'),
  ('voice', '/voice', CommunityTab.feed, 'VOICE'),
  ('player', '/player', CommunityTab.feed, '音声プレーヤー'),
  ('gallery', '/gallery', CommunityTab.feed, 'GALLERY'),
  ('notifications', '/', CommunityTab.notifications, '通知'),
  ('profile', '/', CommunityTab.profile, 'マイページ'),
  ('settings-menu', '/', CommunityTab.more, 'その他'),
  ('states', '/states', CommunityTab.feed, '画面状態と操作'),
];

void main() {
  setUpAll(loadPreviewFont);
  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'ten previews fit width ${width.toInt()} at ${(scale * 100).round()}%',
        (tester) async {
          configureView(
            tester,
            Size(width, width == 768 ? 950 : 820),
            scale: scale,
          );
          for (final (name, route, tab, title) in previewScreens) {
            await showPreview(tester, route: route, tab: tab);
            final header = find.widgetWithText(PageHeader, title);
            expect(header, findsOneWidget, reason: name);
            expect(
              tester.getTopLeft(header).dy,
              greaterThanOrEqualTo(24),
              reason: name,
            );
            expect(tester.getSize(header).width, lessThanOrEqualTo(width));
            expect(tester.takeException(), isNull, reason: name);
            final bar = find.byType(CommunityBar);
            if (route == '/') {
              final last = find.descendant(of: bar, matching: find.text('その他'));
              final barBounds = tester.getRect(bar);
              expect(
                barBounds.bottom - tester.getBottomRight(last).dy,
                greaterThanOrEqualTo(16),
              );
              if (tab == CommunityTab.feed) {
                final fab = tester.getRect(find.byType(ComposeButton));
                expect(fab.bottom, lessThanOrEqualTo(barBounds.top));
              }
            }
          }
        },
      );
    }
  }

  testWidgets('rotation and text scaling recompute responsive layout', (
    tester,
  ) async {
    configureView(tester, const Size(390, 820), scale: 2);
    await showPreview(tester, tab: CommunityTab.content);
    tester.view.physicalSize = const Size(820, 390);
    tester.view.padding = const FakeViewPadding(
      left: 24,
      right: 24,
      bottom: 16,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(PageHeader)).dx,
      greaterThanOrEqualTo(24),
    );
    final tile = find.widgetWithText(ContentTile, 'VOICE');
    await tester.scrollUntilVisible(tile, 200);
    expect(tester.getRect(tile).right, lessThan(796));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'composer supports Japanese text, emoji clusters, attachments and keyboard insets',
    (tester) async {
      configureView(tester, const Size(320, 800), scale: 2);
      await showPreview(tester, route: '/compose');
      final field = find.widgetWithText(TextField, '本文');
      await tester.enterText(field, '朝☀️');
      tester.view.viewInsets = const FakeViewPadding(bottom: 275);
      await tester.pumpAndSettle();
      expect(find.text('2/500'), findsOneWidget);
      final edit = tester.widget<EditableText>(find.byType(EditableText).first);
      expect(edit.focusNode.hasFocus, isTrue);
      final body = find.byType(ListView);
      await tester.drag(body, const Offset(0, -500));
      await tester.pumpAndSettle();
      final send = find.widgetWithText(ActionButton, '投稿する');
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(send).dy, lessThanOrEqualTo(525));
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.text('プレビューの投稿内容を確認しました。'), findsOneWidget);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      final attach = find.byType(AttachmentButton);
      await tester.ensureVisible(attach);
      await tester.tap(attach);
      await tester.pumpAndSettle();
      await tester.tap(find.text('サンプル画像を追加'));
      await tester.pumpAndSettle();
      expect(find.text('画像を追加 (1/3)'), findsOneWidget);
      await tester.tap(find.byTooltip('閉じる'));
      await tester.pumpAndSettle();
      expect(find.text('編集をやめますか？'), findsOneWidget);
      await tester.tap(find.text('編集をやめる'));
      await tester.pumpAndSettle();
      expect(find.byType(ComposeButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('device back asks before leaving the dirty composer', (
    tester,
  ) async {
    await showPreview(tester);
    await tester.tap(find.byType(ComposeButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '本文'), 'きょうの空');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('編集をやめますか？'), findsOneWidget);
    await tester.tap(find.text('戻る').last);
    await tester.pumpAndSettle();
    expect(find.text('きょうの空'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('編集をやめる'));
    await tester.pumpAndSettle();
    expect(find.byType(ComposeButton), findsOneWidget);
  });

  testWidgets('search shows an empty result and can navigate to a match', (
    tester,
  ) async {
    configureView(tester, const Size(390, 820));
    await showPreview(tester, route: '/search');
    final input = find.byType(TextField);
    await tester.enterText(input, 'あいう');
    await tester.pump();
    expect(find.text(ViewState.noResults.title), findsOneWidget);
    await tester.enterText(input, 'さんぽ');
    await tester.pump();
    await tester.tap(find.text('朝のさんぽ便り'));
    await tester.pumpAndSettle();
    expect(find.text('音声プレーヤー'), findsOneWidget);
    await tester.ensureVisible(find.text('再生'));
    await tester.tap(find.text('再生'));
    await tester.pumpAndSettle();
    expect(find.text('一時停止'), findsOneWidget);
    await tester.tap(find.byTooltip('次のトラック'));
    await tester.pumpAndSettle();
    expect(find.text('波の聞こえる場所'), findsOneWidget);
  });

  testWidgets(
    'reduced motion shows a static loading indicator and release shell gates previews',
    (tester) async {
      configureView(tester, const Size(390, 820));
      await showComponent(tester, const StateNotice(ViewState.loading));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(ViewState.loading.title), findsOneWidget);
      await tester.pumpWidget(
        const BootstrapApp(preview: false, initialLocation: '/states'),
      );
      await tester.pumpAndSettle();
      expect(find.text('開発プレビュー'), findsOneWidget);
      expect(find.byType(CommunityBar), findsNothing);
      expect(find.byType(StateNotice), findsNothing);
    },
  );
}
