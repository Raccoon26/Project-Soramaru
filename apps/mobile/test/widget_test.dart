import 'package:bootstrap/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens the Japanese development preview', (tester) async {
    await tester.pumpWidget(const BootstrapApp());

    final title = find.text('開発プレビュー');
    expect(title, findsOneWidget);
    expect(Localizations.localeOf(tester.element(title)), const Locale('ja'));
    expect(tester.takeException(), isNull);
  });
}
