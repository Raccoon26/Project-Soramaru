import 'package:material_ui/material_ui.dart';

void main() => runApp(const BootstrapApp());

class BootstrapApp extends StatelessWidget {
  const BootstrapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '開発プレビュー',
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFFFFB400)),
      home: const Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('開発プレビュー', textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
