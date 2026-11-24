import 'package:bootstrap/ui/content.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:bootstrap/ui/design.dart';
import 'package:bootstrap/ui/feedback.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void main() {
  setUpAll(loadPreviewFont);

  test('design tokens match approved dimensions and color values', () {
    expect(
      [
        Palette.yellow,
        Palette.gold,
        Palette.pink,
        Palette.pinkContrast,
        Palette.blue,
        Palette.link,
        Palette.green,
        Palette.success,
        Palette.ink,
        Palette.secondary,
        Palette.divider,
        Palette.background,
        Palette.surface,
      ].map((color) => color.toARGB32()).toList(),
      [
        0xFFFFB400,
        0xFFEEB73E,
        0xFFFF5A84,
        0xFFBD2E60,
        0xFF5A8FDD,
        0xFF245DA4,
        0xFF0BAA69,
        0xFF087045,
        0xFF252525,
        0xFF5E5E5E,
        0xFFEFEFEF,
        0xFFFAFAFA,
        0xFFFFFFFF,
      ],
    );
    expect(
      [
        Space.xs,
        Space.sm,
        Space.gap,
        Space.edge,
        Space.lg,
        Space.xl,
        Space.section,
      ],
      [4, 8, 12, 16, 20, 24, 32],
    );
    expect(
      [Space.touch, Space.radius, Space.header, Space.navigation, Space.filter],
      [48, 14, 52, 62, 46],
    );
    expect(
      [
        TypeStyles.heading.fontSize,
        TypeStyles.body.fontSize,
        TypeStyles.caption.fontSize,
        TypeStyles.tab.fontSize,
      ],
      [18, 15, 12, 11],
    );
  });

  test('text, error, status, selection and focus have sufficient contrast', () {
    for (final (foreground, background) in [
      (Palette.ink, Palette.surface),
      (Palette.ink, Palette.yellow),
      (Palette.ink, Palette.gold),
      (Palette.secondary, Palette.surface),
      (Palette.secondary, Palette.disabled),
      (Palette.link, Palette.surface),
      (Palette.link, Palette.mutedBlue),
      (Palette.success, Palette.surface),
      (Palette.error, Palette.errorSurface),
      (Palette.surface, Palette.error),
      (Palette.warning, Palette.warm),
      (Palette.surface, Palette.night),
    ]) {
      expect(
        contrastRatio(foreground, background),
        greaterThanOrEqualTo(4.5),
        reason: '$foreground on $background',
      );
    }
    for (final (foreground, background) in [
      (Palette.border, Palette.surface),
      (Palette.focus, Palette.surface),
      (Palette.pinkContrast, Palette.surface),
    ]) {
      expect(contrastRatio(foreground, background), greaterThanOrEqualTo(3));
    }
  });

  testWidgets(
    'enabled, disabled and loading buttons expose the expected actions',
    (tester) async {
      var presses = 0;
      await showComponent(
        tester,
        Column(
          children: [
            ActionButton('確認する', onPressed: () => presses++),
            const ActionButton('選択できません'),
            ActionButton('保存する', loading: true, onPressed: () => presses++),
            IconAction(Icons.close, '閉じる', onPressed: () => presses++),
          ],
        ),
      );
      final enabled = find.widgetWithText(TextButton, '確認する');
      final disabled = find.widgetWithText(TextButton, '選択できません');
      final loading = find.widgetWithText(TextButton, '処理中…');
      expect(tester.getSize(enabled).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byType(IconButton)), const Size(48, 48));
      expect(tester.widget<TextButton>(disabled).onPressed, isNull);
      expect(tester.widget<TextButton>(loading).onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(enabled);
      expect(presses, 1);
    },
  );

  testWidgets(
    'filter selection and navigation unread semantics reflect the model',
    (tester) async {
      final semantics = tester.ensureSemantics();

      FeedCategory category = FeedCategory.all;
      CommunityTab tab = CommunityTab.feed;
      await showComponent(
        tester,
        StatefulBuilder(
          builder: (context, update) => Column(
            children: [
              CategoryStrip(
                selected: category,
                onSelect: (value) => update(() => category = value),
              ),
              CommunityBar(
                selected: tab,
                unread: 112,
                onSelect: (value) => update(() => tab = value),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('公式'));
      await tester.tap(find.bySemanticsLabel('通知、未読112件'));
      await tester.pumpAndSettle();
      final filter = tester
          .getSemantics(find.bySemanticsLabel('公式'))
          .getSemanticsData();
      final notification = tester
          .getSemantics(find.bySemanticsLabel('通知、未読112件'))
          .getSemanticsData();
      expect(filter.flagsCollection.isSelected.toBoolOrNull(), isTrue);
      expect(notification.flagsCollection.isSelected.toBoolOrNull(), isTrue);
      expect(
        tester.getSize(find.bySemanticsLabel('公式')).height,
        greaterThanOrEqualTo(48),
      );
      expect(find.text('99+'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('ファン投稿'))
            .getSemanticsData()
            .flagsCollection
            .isSelected
            .toBoolOrNull(),
        isFalse,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'post contains badge, pinned status, long tags, attachments and reactions',
    (tester) async {
      const post = FeedPost(
        author: 'プレビュー編集部',
        time: 'きょう',
        official: true,
        pinned: true,
        body: '朝の散歩で遠くの丘に日が差していました。空の色が変わっていくのを見ていたら、いつもの道も少し違って見えました。',
        tags: ['きょうの空', '季節の便り'],
        photos: [Landscape(CoverScene.morning), Landscape(CoverScene.garden)],
        likes: 12,
        comments: 4,
        liked: true,
      );
      configureView(tester, const Size(320, 780), scale: 2);
      final semantics = tester.ensureSemantics();

      await showComponent(
        tester,
        const SingleChildScrollView(child: PostCard(post)),
      );
      expect(find.text(post.body), findsOneWidget);
      expect(find.text('#季節の便り'), findsOneWidget);
      expect(find.text('公式サンプル'), findsOneWidget);
      expect(find.text('固定のお知らせ'), findsOneWidget);
      expect(find.byType(MediaFrame), findsNWidgets(2));
      expect(find.bySemanticsLabel('いいね 12件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('voice and gallery art keep their distinct aspect ratios', (
    tester,
  ) async {
    await showComponent(
      tester,
      SizedBox(
        width: 180,
        child: ListView(
          children: [
            MediaCard(
              title: '音声',
              detail: '3:48',
              cover: const Landscape(CoverScene.morning),
              onPressed: () {},
            ),
            MediaCard(
              title: '写真',
              detail: '2枚',
              cover: const Landscape(CoverScene.coast),
              album: true,
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    final art = find.byType(MediaFrame);
    final wide = tester.getSize(art.at(0));
    final portrait = tester.getSize(art.at(1));
    expect(wide.aspectRatio, closeTo(16 / 9, .001));
    expect(portrait.aspectRatio, closeTo(3 / 4, .001));
  });

  testWidgets('error notices keep existing data visible and can be retried', (
    tester,
  ) async {
    var retry = 0;
    await showComponent(
      tester,
      Column(
        children: [
          const Text('表示済みの投稿'),
          const StateNotice(ViewState.empty),
          StateNotice(ViewState.network, compact: true, onRetry: () => retry++),
        ],
      ),
    );
    expect(find.text('表示済みの投稿'), findsOneWidget);
    expect(find.text(ViewState.empty.title), findsOneWidget);
    expect(find.text(ViewState.network.title), findsOneWidget);
    await tester.tap(find.text('再試行'));
    expect(retry, 1);
  });

  testWidgets(
    'confirmation places focus on cancel and returns false on system back',
    (tester) async {
      bool? result;
      await showComponent(
        tester,
        Builder(
          builder: (context) => ActionButton(
            '削除',
            onPressed: () async {
              result = await confirmAction(
                context,
                title: '削除しますか？',
                message: 'プレビューの項目です。',
                action: '削除する',
                destructive: true,
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('削除'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final cancel = find.widgetWithText(TextButton, '戻る');
      expect(tester.widget<TextButton>(cancel).autofocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(result, isFalse);
    },
  );

  testWidgets('bottom sheet closes with its dedicated control', (tester) async {
    configureView(tester, const Size(320, 570), scale: 2);
    await showComponent(
      tester,
      Builder(
        builder: (context) => ActionButton(
          '開く',
          onPressed: () {
            showActions(context, '画像を追加', const [SettingsRow('サンプル画像を追加')]);
          },
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('サンプル画像を追加'), findsOneWidget);
    await tester.tap(find.byTooltip('閉じる'));
    await tester.pumpAndSettle();
    expect(find.text('サンプル画像を追加'), findsNothing);
  });
}
