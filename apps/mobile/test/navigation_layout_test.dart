import 'dart:io';
import 'dart:ui' as ui;

import 'package:bootstrap/navigation/destinations.dart';
import 'package:bootstrap/navigation/ja.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'navigation_support.dart';

void main() {
  setUpAll(loadNavigationFont);

  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'navigation renders at ${width.toInt()}px, ${(scale * 100).round()}%',
        (tester) async {
          await launchNavigation(tester, size: Size(width, 800), scale: scale);
          for (final tab in CommunityTab.values) {
            if (tab != CommunityTab.feed) await tapTab(tester, tab);
            final route = Screen.tabs[tab.index];
            expect(find.byType(CommunityBar), findsOneWidget);
            expect(header(route), findsOneWidget);
            final bounds = tester.getRect(header(route));
            expect(bounds.top, greaterThanOrEqualTo(24));
            expect(bounds.width, lessThanOrEqualTo(width));
            expect(tester.takeException(), isNull);
          }
          await goTo(tester, Screen.photo, 'album-1');
          expect(find.byType(CommunityBar), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'membership stays legible after landscape rotation and dismisses',
    (tester) async {
      await launchNavigation(tester, scale: 2);
      await tapTab(tester, CommunityTab.profile);
      await goTo(tester, Screen.membership);
      tester.view.physicalSize = const Size(820, 390);
      tester.view.padding = const FakeViewPadding(
        left: 24,
        right: 24,
        bottom: 16,
      );
      await tester.pumpAndSettle();
      expect(find.text('会員証プレビュー'), findsOneWidget);
      expect(
        tester.getTopLeft(header(Screen.membership)).dx,
        greaterThanOrEqualTo(24),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('iOS route types and reduced motion honor platform settings', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await launchNavigation(tester, reduceMotion: false);
    await goTo(tester, Screen.search);
    final normal = ModalRoute.of(tester.element(header(Screen.search)))!;
    expect(normal.settings, isA<MaterialPage<Object?>>());
    expect(normal.fullscreenDialog, isFalse);
    expect(normal.popGestureEnabled, isTrue);
    await goTo(tester, Screen.compose);
    final composer = ModalRoute.of(
      tester.element(find.byType(TextField).first),
    )!;
    expect(composer.fullscreenDialog, isTrue);
    expect(composer.popGestureEnabled, isFalse);
    await tester.tap(find.byTooltip(Ja.close));
    await tester.pumpAndSettle();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    await tester.pumpAndSettle();
    await goTo(tester, Screen.tags);
    final reduced = ModalRoute.of(tester.element(header(Screen.tags)))!;
    expect(reduced.settings, isA<NoTransitionPage<Object?>>());
  });

  if (const bool.fromEnvironment('CAPTURE_DEV02')) {
    testWidgets('exports a series of synthetic DEV-02 flows', (tester) async {
      await launchNavigation(tester);
      Future<void> capture(String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(navFrame),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final out = Directory('../../.local/dev-02-preview');
            await out.create(recursive: true);
            await File('${out.path}/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      await capture('01-feed');
      await goTo(tester, Screen.post, 'post-1');
      await capture('02-post');
      await goTo(tester, Screen.comments, 'post-1');
      await capture('03-comments');
      await tapTab(tester, CommunityTab.feed);
      await goTo(tester, Screen.compose);
      await tester.enterText(find.byType(TextField).first, '朝の空を眺めました。');
      await tester.pumpAndSettle();
      await capture('04-compose');
      await tester.tap(find.text('タグを追加'));
      await tester.pumpAndSettle();
      await capture('05-tags');
      nav(tester).back();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('閉じる'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('編集を破棄'));
      await tester.pumpAndSettle();
      await tapTab(tester, CommunityTab.content);
      await capture('06-content');
      await goTo(tester, Screen.voiceDetail, 'voice-1');
      await capture('07-audio-detail');
      await goTo(tester, Screen.player, 'voice-1');
      await capture('08-player');
      nav(tester).back();
      await tester.pumpAndSettle();
      await goTo(tester, Screen.album, 'album-1');
      await capture('09-album');
      await tapTab(tester, CommunityTab.notifications);
      await capture('10-notifications');
      await tapTab(tester, CommunityTab.profile);
      await goTo(tester, Screen.membership);
      await capture('11-membership');
      nav(tester).back();
      await tester.pumpAndSettle();
      nav(tester).receiveExternal('soramaru-dev://open/post/deleted');
      await tester.pumpAndSettle();
      await capture('12-unavailable');
    });
  }
}
