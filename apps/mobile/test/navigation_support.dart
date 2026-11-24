import 'dart:io';

import 'package:bootstrap/navigation/destinations.dart';
import 'package:bootstrap/navigation/ja.dart';
import 'package:bootstrap/navigation/navigation_app.dart';
import 'package:bootstrap/navigation/session.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

const navFrame = ValueKey('navigation-preview-frame');

Future<void> loadNavigationFont() async {
  final font = FontLoader('Soramaru Navigation JP')
    ..addFont(
      File('test/fixtures/SoramaruNavigationJP.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([font.load(), icons.load()]);
}

class TestIdentity extends DemoIdentity {
  TestIdentity(this.initial);
  final DemoSession initial;

  @override
  DemoSession build() => initial;
}

ProviderContainer providers(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(NavigationApp)),
  listen: false,
);
NavigationController nav(WidgetTester tester) =>
    providers(tester).read(navigationProvider);
DemoIdentity identity(WidgetTester tester) =>
    providers(tester).read(demoSessionProvider.notifier);

Future<void> launchNavigation(
  WidgetTester tester, {
  String? link,
  DemoSession session = const DemoSession(),
  DateTime Function()? clock,
  Size size = const Size(390, 820),
  double scale = 1,
  bool reduceMotion = true,
}) async {
  configureView(tester, size, scale: scale, reduceMotion: reduceMotion);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        demoSessionProvider.overrideWith(() => TestIdentity(session)),
        initialExternalLinkProvider.overrideWithValue(link),
        if (clock != null) navigationClockProvider.overrideWithValue(clock),
      ],
      child: const RepaintBoundary(
        key: navFrame,
        child: NavigationApp(fontFamily: 'Soramaru Navigation JP'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapTab(WidgetTester tester, CommunityTab tab) async {
  final label = find.descendant(
    of: find.byType(CommunityBar),
    matching: find.text(tab.label),
  );
  await tester.tap(label);
  await tester.pumpAndSettle();
}

Future<void> goTo(WidgetTester tester, Screen screen, [String? id]) async {
  nav(tester).open<void>(Destination(screen, id));
  await tester.pumpAndSettle();
  expect(nav(tester).current, screen);
}

Finder header(Screen screen) =>
    find.widgetWithText(PageHeader, Ja.title(screen));
