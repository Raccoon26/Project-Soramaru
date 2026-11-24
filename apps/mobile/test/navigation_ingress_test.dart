import 'package:bootstrap/main.dart';
import 'package:bootstrap/navigation/destinations.dart';
import 'package:bootstrap/navigation/ja.dart';
import 'package:bootstrap/navigation/navigation_app.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'navigation_support.dart';

void main() {
  setUpAll(loadNavigationFont);

  testWidgets(
    'cold deep link constructs ancestor stack and back returns to branch root',
    (tester) async {
      await launchNavigation(tester, link: 'soramaru-dev://open/voice/voice-1');
      expect(nav(tester).current, Screen.voiceDetail);
      expect(
        tester.widget<CommunityBar>(find.byType(CommunityBar)).selected,
        CommunityTab.content,
      );
      await tester.tap(find.byTooltip(Ja.back));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.voice);
    },
  );

  testWidgets(
    'warm deep link preserves source tab and invalid URI does not open content',
    (tester) async {
      await launchNavigation(tester);
      final n = nav(tester);
      expect(n.receiveExternal('soramaru-dev://open/album/album-1'), isTrue);
      await tester.pumpAndSettle();
      expect(n.current, Screen.album);
      await tester.tap(find.byTooltip(Ja.back));
      await tester.pumpAndSettle();
      expect(n.current, Screen.feed);
      n.receiveExternal('https://example.invalid/#/profile');
      await tester.pumpAndSettle();
      expect(n.current, Screen.invalidLink);
      expect(find.text(Ja.badLink), findsOneWidget);
    },
  );

  testWidgets('cold protected link waits and resumes after demo sign-in', (
    tester,
  ) async {
    await launchNavigation(
      tester,
      link: 'soramaru-dev://open/post/post-1',
      session: const DemoSession(
        status: SessionStatus.signedOut,
        account: null,
      ),
    );
    expect(nav(tester).current, Screen.login);
    expect(header(Screen.post), findsNothing);
    await tester.tap(find.text('サンプル会員で続ける'));
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.post);
    expect(header(Screen.post), findsOneWidget);
  });

  testWidgets(
    'expired pending destination and unauthorized artist route do not open protected UI',
    (tester) async {
      var now = DateTime.utc(2026, 11, 24);
      await launchNavigation(
        tester,
        session: const DemoSession(
          status: SessionStatus.signedOut,
          account: null,
        ),
        clock: () => now,
      );
      nav(tester).receiveExternal('soramaru-dev://open/voice/voice-1');
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.login);
      now = now.add(const Duration(minutes: 5));
      await tester.tap(find.text('サンプル会員で続ける'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.feed);
      nav(tester).router.go(Screen.artistPost.pattern);
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.restricted);
      expect(header(Screen.artistPost), findsNothing);
      identity(tester).change(SessionStatus.member, role: MemberRole.artist);
      await tester.pumpAndSettle();
      await goTo(tester, Screen.artistPost);
      identity(tester)
          .change(SessionStatus.member, role: MemberRole.administrator);
      await tester.pumpAndSettle();
      nav(tester).router.go(Screen.artistPost.pattern);
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.restricted);
    },
  );

  testWidgets(
    'expired session clears prior branch stack before fresh sign-in',
    (tester) async {
      await launchNavigation(tester);
      await tapTab(tester, CommunityTab.profile);
      await goTo(tester, Screen.membership);
      identity(tester).change(SessionStatus.expired);
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.feed);
      expect(header(Screen.membership), findsNothing);
      await tapTab(tester, CommunityTab.profile);
      expect(nav(tester).current, Screen.login);
      await tester.tap(find.text('サンプル会員で続ける'));
      await tester.pumpAndSettle();
      expect(nav(tester).current, Screen.feed);
    },
  );

  testWidgets('back out of login discards the pre-login target', (
    tester,
  ) async {
    await launchNavigation(
      tester,
      session: const DemoSession(
        status: SessionStatus.signedOut,
        account: null,
      ),
    );
    nav(tester).receiveExternal('soramaru-dev://open/voice/voice-1');
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.login);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.feed);
    identity(tester).change(SessionStatus.member);
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.feed);
  });

  testWidgets(
    'background and foreground preserve in-memory search and router',
    (tester) async {
      await launchNavigation(tester);
      await goTo(tester, Screen.search);
      await tester.enterText(find.byType(TextField), '朝の散歩');
      final original = nav(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(nav(tester), same(original));
      expect(nav(tester).current, Screen.search);
      expect(find.text('朝の散歩'), findsOneWidget);
    },
  );

  testWidgets(
    'deleted, denied and unknown targets have recovery and retain source',
    (tester) async {
      await launchNavigation(tester);
      for (final (id, text) in [
        ('deleted', Ja.removed),
        ('private', Ja.privateContent),
        ('unknown', Ja.missing),
      ]) {
        nav(tester).receiveExternal('soramaru-dev://open/post/$id');
        await tester.pumpAndSettle();
        expect(nav(tester).current, Screen.unavailable);
        expect(find.text(text), findsOneWidget);
        await tester.tap(find.byTooltip(Ja.close));
        await tester.pumpAndSettle();
        expect(nav(tester).current, Screen.feed);
      }
    },
  );

  testWidgets(
    'process recreation restores tab, stack and media filter, with a new runtime',
    (tester) async {
      await launchNavigation(tester);
      await tapTab(tester, CommunityTab.content);
      await goTo(tester, Screen.voice);
      await tester.tap(find.text('RADIO'));
      await tester.pumpAndSettle();
      await tapTab(tester, CommunityTab.profile);
      await goTo(tester, Screen.cards);
      final original = nav(tester);
      await tester.restartAndRestore();
      await tester.pumpAndSettle();
      expect(identical(nav(tester), original), isFalse);
      expect(nav(tester).current, Screen.cards);
      await tapTab(tester, CommunityTab.content);
      expect(nav(tester).current, Screen.voice);
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).selected, 2);
    },
  );

  testWidgets('restoration excludes typed search and draft input', (
    tester,
  ) async {
    await launchNavigation(tester);
    await goTo(tester, Screen.search);
    await tester.enterText(find.byType(TextField), '検索中のテスト');
    await tester.pumpAndSettle();
    await tester.restartAndRestore();
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.search);
    expect(find.text('検索中のテスト'), findsNothing);
    await tapTab(tester, CommunityTab.feed);
    await goTo(tester, Screen.compose);
    await tester.enterText(find.byType(TextField).first, '下書き中のテスト');
    await tester.pumpAndSettle();
    await tester.restartAndRestore();
    await tester.pumpAndSettle();
    expect(find.text('下書き中のテスト'), findsNothing);
  });

  testWidgets('non-preview entry never routes to the mock login', (
    tester,
  ) async {
    await tester.pumpWidget(
      const BootstrapApp(preview: false, initialLocation: '/login'),
    );
    await tester.pumpAndSettle();
    expect(find.text(Ja.preview), findsOneWidget);
    expect(find.byType(NavigationApp), findsNothing);
    expect(find.text('サンプル会員で続ける'), findsNothing);
  });
}
