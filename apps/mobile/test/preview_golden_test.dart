import 'dart:io';
import 'dart:ui' as ui;

import 'package:bootstrap/ui/controls.dart';
import 'package:bootstrap/ui/feedback.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'preview_layout_test.dart' show previewScreens;
import 'support.dart';

String _goldenPath(String name) =>
    Platform.isLinux ? 'goldens/linux/$name.png' : 'goldens/$name.png';

void main() {
  final supportsGolden = Platform.isWindows || Platform.isLinux;
  setUpAll(loadPreviewFont);

  testWidgets('category and empty state golden', (tester) async {
    configureView(tester, const Size(390, 390));
    await showComponent(
      tester,
      RepaintBoundary(
        key: frameKey,
        child: ColoredBox(
          color: Colors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CategoryStrip(selected: FeedCategory.official, onSelect: (_) {}),
              const Padding(
                padding: EdgeInsets.all(16),
                child: StateNotice(ViewState.empty),
              ),
            ],
          ),
        ),
      ),
    );
    await expectLater(
      find.byKey(frameKey),
      matchesGoldenFile(_goldenPath('category-and-empty')),
    );
  }, skip: !supportsGolden);

  testWidgets('fan feed screen golden', (tester) async {
    configureView(tester, const Size(390, 820));
    await showPreview(tester);
    await expectLater(
      find.byKey(frameKey),
      matchesGoldenFile(_goldenPath('fan-feed')),
    );
  }, skip: !supportsGolden);

  if (const bool.fromEnvironment('CAPTURE_DEV01')) {
    testWidgets('export the ten synthetic preview screens locally', (
      tester,
    ) async {
      configureView(tester, const Size(390, 820));
      for (final (index, (name, route, tab, _)) in previewScreens.indexed) {
        await showPreview(tester, route: route, tab: tab);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(frameKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = Directory('../../.local/dev-01-preview');
            await output.create(recursive: true);
            final prefix = (index + 1).toString().padLeft(2, '0');
            await File('${output.path}/$prefix-$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    });
  }
}
