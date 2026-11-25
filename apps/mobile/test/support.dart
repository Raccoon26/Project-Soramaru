import 'dart:io';

import 'package:bootstrap/community/drafts.dart';
import 'package:bootstrap/main.dart';
import 'package:bootstrap/ui/controls.dart';
import 'package:bootstrap/ui/design.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class Keys implements DraftKeys {
  final values = <String, String>{};
  @override
  Future<String?> read(String owner) async => values[owner];
  @override
  Future<void> write(String owner, String key) async => values[owner] = key;
  @override
  Future<void> remove(String owner) async => values.remove(owner);
}

const previewFont = 'Soramaru Test JP';
const frameKey = ValueKey('preview-frame');

Future<void> loadPreviewFont() async {
  final font = FontLoader(previewFont);
  font.addFont(
    File('test/fixtures/SoramaruTestJP.ttf')
        .readAsBytes()
        .then(ByteData.sublistView),
  );
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([font.load(), icons.load()]);
}

void configureView(
  WidgetTester tester,
  Size size, {
  double scale = 1,
  bool reduceMotion = true,
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 16);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduceMotion);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
}

Future<void> showPreview(
  WidgetTester tester, {
  String route = '/',
  CommunityTab tab = CommunityTab.feed,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: frameKey,
      child: BootstrapApp(
        key: UniqueKey(),
        initialLocation: route,
        fontFamily: previewFont,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (tab != CommunityTab.feed) {
    await tester.tap(find.text(tab.label).last);
    await tester.pumpAndSettle();
  }
}

Future<void> showComponent(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: soramaruTheme(fontFamily: previewFont),
      home: Scaffold(
        body: SafeArea(
          child: Align(alignment: Alignment.topCenter, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}
