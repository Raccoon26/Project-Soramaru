import 'package:bootstrap/navigation/destinations.dart';
import 'package:bootstrap/navigation/ja.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'navigation_support.dart';

Future<void> openLabel(WidgetTester tester, String label, Screen target) async {
  final row = find.text(label);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(nav(tester).current, target);
}

Future<void> backTo(WidgetTester tester, Screen target) async {
  final fullScreen = nav(tester).current?.fullScreen ?? false;
  await tester.tap(find.byTooltip(fullScreen ? Ja.close : Ja.back));
  await tester.pumpAndSettle();
  expect(nav(tester).current, target);
}

void main() {
  setUpAll(loadNavigationFont);

  testWidgets(
    'feed search, popular tags and stamp sheet use the normal entry points',
    (tester) async {
      await launchNavigation(tester);
      await tester.tap(find.byTooltip(Ja.title(Screen.search)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '朝の散歩');
      await tester.pumpAndSettle();
      await openLabel(tester, '散歩の記録', Screen.post);
      await openLabel(tester, Ja.title(Screen.comments), Screen.comments);
      await tester.tap(find.text('スタンプを見る'));
      await tester.pumpAndSettle();
      expect(find.text('拍手'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('拍手'), findsNothing);
      expect(nav(tester).current, Screen.comments);
      await tapTab(tester, CommunityTab.feed);
      await openLabel(tester, Ja.title(Screen.tags), Screen.tags);
      await openLabel(tester, '#きょうの空', Screen.tagged);
    },
  );

  testWidgets(
    'content hub connects each neighboring collection and announcement',
    (tester) async {
      await launchNavigation(tester);
      await tapTab(tester, CommunityTab.content);
      await openLabel(tester, Ja.title(Screen.today), Screen.today);
      await backTo(tester, Screen.content);
      await openLabel(tester, Ja.title(Screen.voice), Screen.voice);
      await openLabel(tester, Ja.title(Screen.playlist), Screen.playlist);
      await backTo(tester, Screen.voice);
      await openLabel(tester, Ja.title(Screen.downloads), Screen.downloads);
      await backTo(tester, Screen.voice);
      await backTo(tester, Screen.content);
      await openLabel(tester, Ja.title(Screen.recent), Screen.recent);
      await openLabel(tester, '朝のさんぽ便り', Screen.voiceDetail);
      await backTo(tester, Screen.recent);
      await backTo(tester, Screen.content);
      await openLabel(tester, Ja.title(Screen.notices), Screen.notices);
      await openLabel(tester, 'プレビューのお知らせ', Screen.notice);
      await backTo(tester, Screen.notices);
      await backTo(tester, Screen.content);
      await openLabel(tester, Ja.title(Screen.goods), Screen.goods);
      expect(find.text('ご案内できるリンクはありません。'), findsOneWidget);
    },
  );

  testWidgets('profile actions open each child and retain the source branch', (
    tester,
  ) async {
    await launchNavigation(tester);
    await tapTab(tester, CommunityTab.profile);
    await openLabel(tester, Ja.title(Screen.editProfile), Screen.editProfile);
    await tester.enterText(find.byType(TextField), '変更前の確認');
    await tester.pumpAndSettle();
    await tester.tap(find.text(Ja.cancel));
    await tester.pumpAndSettle();
    expect(nav(tester).current, Screen.profile);
    expect(find.text('変更前の確認'), findsNothing);

    await openLabel(tester, Ja.title(Screen.membership), Screen.membership);
    await backTo(tester, Screen.profile);

    await openLabel(tester, Ja.title(Screen.badges), Screen.badges);
    await openLabel(tester, '朝のさんぽ', Screen.badge);
    await tester.tap(find.text('バッジを試す'));
    await tester.pumpAndSettle();
    expect(nav(tester).badgeApplied.value, isTrue);
    await backTo(tester, Screen.badges);
    await backTo(tester, Screen.profile);

    await openLabel(tester, Ja.title(Screen.cards), Screen.cards);
    await openLabel(tester, Ja.title(Screen.card), Screen.card);
    await backTo(tester, Screen.cards);
    await backTo(tester, Screen.profile);

    await openLabel(tester, Ja.title(Screen.activity), Screen.activity);
    await openLabel(tester, '散歩の記録', Screen.post);
    await backTo(tester, Screen.activity);
    await backTo(tester, Screen.profile);

    await openLabel(tester, Ja.title(Screen.favorites), Screen.favorites);
    await openLabel(tester, 'ユーザー', Screen.user);
    await backTo(tester, Screen.favorites);
    await openLabel(tester, 'タグ', Screen.tagged);
    await backTo(tester, Screen.favorites);
    await backTo(tester, Screen.profile);

    await openLabel(tester, Ja.title(Screen.collections), Screen.collections);
    await openLabel(tester, '空の風景', Screen.folder);
    await openLabel(tester, '夕暮れの色', Screen.album);
    await backTo(tester, Screen.folder);
    await backTo(tester, Screen.collections);
    await backTo(tester, Screen.profile);

    await openLabel(tester, Ja.title(Screen.devices), Screen.devices);
    await openLabel(tester, '端末サンプル', Screen.device);
    await backTo(tester, Screen.devices);
    await backTo(tester, Screen.profile);
    await openLabel(tester, Ja.title(Screen.blocks), Screen.blocks);
    expect(find.text('ブロック中のユーザーはいません。'), findsOneWidget);
  });
}
