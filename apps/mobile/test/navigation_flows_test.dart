import 'package:bootstrap/navigation/destinations.dart';
import 'package:bootstrap/navigation/ja.dart';
import 'package:bootstrap/navigation/sample_data.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:bootstrap/preview/pages.dart' show ComposeDraft;
import 'package:bootstrap/ui/controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'navigation_support.dart';

void main() {
  setUpAll(loadNavigationFont);

  testWidgets(
    'independent tabs restore search and content filters without recreating router',
    (tester) async {
      await launchNavigation(tester);
      final controller = nav(tester);
      await goTo(tester, Screen.search);
      await tester.enterText(find.byType(TextField), '朝の散歩');
      await tester.tap(find.text('投稿'));
      await tester.pumpAndSettle();
      await tapTab(tester, CommunityTab.content);
      await goTo(tester, Screen.voice);
      await tester.tap(find.text('RADIO'));
      await tester.pumpAndSettle();
      await tapTab(tester, CommunityTab.feed);
      expect(nav(tester).current, Screen.search);
      expect(find.text('朝の散歩'), findsOneWidget);
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).selected, 1);
      await tapTab(tester, CommunityTab.content);
      expect(nav(tester).current, Screen.voice);
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).selected, 2);
      expect(identical(controller, nav(tester)), isTrue);
    },
  );

  testWidgets(
    'feed scroll and category survive tab switch and root reselection resets scroll',
    (tester) async {
      await launchNavigation(tester, size: const Size(390, 600));
      final list = nav(tester).scrollFor(CommunityTab.feed);
      await tester.drag(find.byType(ListView).first, const Offset(0, -380));
      await tester.pumpAndSettle();
      final before = list.offset;
      expect(before, greaterThan(0));
      await tapTab(tester, CommunityTab.profile);
      await tapTab(tester, CommunityTab.feed);
      expect(list.offset, closeTo(before, .01));
      await tapTab(tester, CommunityTab.feed);
      expect(list.offset, 0);
      await tester.tap(find.text('公式'));
      await tester.pumpAndSettle();
      await tapTab(tester, CommunityTab.more);
      await tapTab(tester, CommunityTab.feed);
      expect(
        tester.widget<CategoryStrip>(find.byType(CategoryStrip)).selected,
        FeedCategory.official,
      );
      await goTo(tester, Screen.search);
      await tapTab(tester, CommunityTab.feed);
      expect(nav(tester).current, Screen.feed);
    },
  );

  testWidgets('opening post and comments then backing out restores feed', (
    tester,
  ) async {
    await launchNavigation(tester);
    await tester.tap(find.textContaining('音声とギャラリーのサンプルを追加しました。').first);
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.post);
    await tester.tap(find.text(Ja.title(Screen.comments)));
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.comments);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.post);
    await tester.tap(find.byTooltip(Ja.back));
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.feed);
  });

  testWidgets(
    'composer retains text, tags and selected art across routes and guards dirty exit',
    (tester) async {
      await launchNavigation(tester);
      await goTo(tester, Screen.compose);
      await tester.enterText(find.widgetWithText(TextField, '本文'), '朝の便り');
      await tester.pumpAndSettle();
      await tester.tap(find.text('タグを追加'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.pickTag);
      await tester.tap(find.text('朝の散歩'));
      await tester.pumpAndSettle();
      expect(find.text('#朝の散歩'), findsOneWidget);
      expect(find.text('朝の便り'), findsOneWidget);
      await tester.ensureVisible(find.text('画像を追加 (0/3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画像を追加 (0/3)'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.pickPhoto);
      await tester.tap(find.text('海辺の風景'));
      await tester.pumpAndSettle();
      expect(find.text('画像を追加 (1/3)'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('編集を終了しますか？'), findsOneWidget);
      await tester.tap(find.text('編集を続ける'));
      await tester.pumpAndSettle();
      expect(find.text('朝の便り'), findsOneWidget);
      await tester.tap(find.byTooltip(Ja.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一時保存して戻る'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.feed);
      await goTo(tester, Screen.compose);
      expect(find.text('朝の便り'), findsOneWidget);
    },
  );

  testWidgets(
    'voice and gallery use full-screen routes and return to their source lists',
    (tester) async {
      await launchNavigation(tester);
      await tapTab(tester, CommunityTab.content);
      await tester.tap(find.text(Ja.title(Screen.voice)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('朝のさんぽ便り'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('プレーヤーを開く'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.player);
      expect(find.byType(CommunityBar), findsNothing);
      await tester.tap(find.byTooltip(Ja.close));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.voiceDetail);
      await tapTab(tester, CommunityTab.content);
      await tester.tap(find.text(Ja.title(Screen.gallery)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('夕暮れの色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('写真ビューアを開く'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.photo);
      expect(find.byType(CommunityBar), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.album);
    },
  );

  testWidgets(
    'notification handoff changes branch, preserves unread count and returns on back',
    (tester) async {
      await launchNavigation(tester);
      await goTo(tester, Screen.search);
      await tester.enterText(find.byType(TextField), '朝の散歩');
      await tester.pumpAndSettle();
      await tapTab(tester, CommunityTab.notifications);
      await tester.tap(find.text('投稿にコメントが届きました'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.comments);
      expect(
        tester.widget<CommunityBar>(find.byType(CommunityBar)).selected,
        CommunityTab.feed,
      );
      expect(tester.widget<CommunityBar>(find.byType(CommunityBar)).unread, 2);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.notifications);
      await tapTab(tester, CommunityTab.feed);
      expect(nav(tester).current, Screen.search);
      expect(find.text('朝の散歩'), findsOneWidget);
    },
  );

  testWidgets('all notification kinds open and return without acknowledging', (
    tester,
  ) async {
    await launchNavigation(tester);
    await tapTab(tester, CommunityTab.notifications);
    for (final notice in sampleNotices) {
      final row = find.text(notice.title);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(nav(tester).currentPath, notice.target.location);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.notifications);
      expect(tester.widget<CommunityBar>(find.byType(CommunityBar)).unread, 2);
    }
  });

  testWidgets('notification return leaves an already open target on its tab', (
    tester,
  ) async {
    await launchNavigation(tester);
    await goTo(tester, Screen.comments, 'post-1');
    await tapTab(tester, CommunityTab.notifications);
    await tester.tap(find.text(sampleNotices.first.title));
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.comments);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.notifications);
    await tapTab(tester, CommunityTab.feed);
    expect(nav(tester).current, Screen.comments);
  });

  testWidgets(
    'account change gets a new router and clears private draft and profile state',
    (tester) async {
      await launchNavigation(tester);
      final previous = nav(tester);
      previous.draft = const ComposeDraft('下書きサンプル', [], []);
      await tapTab(tester, CommunityTab.profile);
      await goTo(tester, Screen.editProfile);
      await tester.enterText(find.byType(TextField), '合成テスト');
      await tester.tap(find.text(Ja.saveDemo));
      await tester.pumpAndSettle();
      expect(find.text('合成テスト'), findsOneWidget);
      identity(tester).change(SessionStatus.member, account: 'demo-b');
      await tester.pumpAndSettle();
      expect(identical(nav(tester), previous), isFalse);
      expect(nav(tester).draft, isNull);
      expect(nav(tester).current, Screen.feed);
      await tapTab(tester, CommunityTab.profile);
      expect(find.text('合成テスト'), findsNothing);
      expect(find.text('プレビュー会員'), findsOneWidget);
    },
  );

  testWidgets('guest login and placeholder policies remain usable from More', (
    tester,
  ) async {
    await launchNavigation(
      tester,
      session: const DemoSession(
        status: SessionStatus.signedOut,
        account: null,
      ),
    );
    await tapTab(tester, CommunityTab.more);
    for (final screen in [Screen.terms, Screen.privacy, Screen.support]) {
      await tester.tap(find.text(Ja.title(screen)));
      await tester.pumpAndSettle();
      expect(header(screen), findsOneWidget);
      await tester.tap(find.byTooltip(Ja.back));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.more);
    }
    final signIn = find.text(Ja.title(Screen.login));
    await tester.ensureVisible(signIn);
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.login);
    await tester.tap(find.text(Ja.demoSignIn));
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.feed);
  });

  testWidgets(
    'rapid duplicate opens and branch root back leave one predictable stack',
    (tester) async {
      await launchNavigation(tester);
      final navigation = nav(tester);
      navigation.open<void>(const Destination(Screen.search));
      navigation.open<void>(const Destination(Screen.search));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.search);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.feed);
      await tapTab(tester, CommunityTab.content);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.feed);
    },
  );
}
