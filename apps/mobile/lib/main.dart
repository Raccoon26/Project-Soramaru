import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'preview/home.dart';
import 'preview/pages.dart';
import 'ui/design.dart';

const _enablePreview = bool.fromEnvironment(
  'DEV_PREVIEW',
  defaultValue: !kReleaseMode,
);

void main() => runApp(const BootstrapApp(preview: _enablePreview));

class BootstrapApp extends StatelessWidget {
  const BootstrapApp({
    super.key,
    this.preview = true,
    this.initialLocation = '/',
    this.fontFamily,
  });

  final bool preview;
  final String initialLocation;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    if (preview) {
      return ProviderScope(
        overrides: [_initialLocation.overrideWithValue(initialLocation)],
        child: _PreviewApp(fontFamily: fontFamily),
      );
    }
    return MaterialApp(
      title: '開発プレビュー',
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: soramaruTheme(fontFamily: fontFamily),
      home: const Scaffold(
        body: SafeArea(child: Center(child: Text('開発プレビュー'))),
      ),
    );
  }
}

final _initialLocation = Provider<String>((ref) => '/');

final _router = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: ref.watch(_initialLocation),
    routes: [
      _route('/', (_) => const PreviewHome()),
      _route('/compose', (_) => const ComposePreview()),
      _route('/voice', (_) => const MediaListPreview()),
      _route('/gallery', (_) => const MediaListPreview(album: true)),
      _route(
        '/player',
        (state) => PlayerPreview(
          initialTrack: state.uri.queryParameters['track'] == '1' ? 1 : 0,
        ),
      ),
      _route('/search', (_) => const SearchPreview()),
      _route('/settings', (_) => const SettingsPreview()),
      _route('/states', (_) => const StateCatalog()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

GoRoute _route(String path, Widget Function(GoRouterState) child) => GoRoute(
  path: path,
  pageBuilder: (context, state) =>
      NoTransitionPage(key: state.pageKey, child: child(state)),
);

class _PreviewApp extends ConsumerWidget {
  const _PreviewApp({required this.fontFamily});
  final String? fontFamily;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: '開発プレビュー',
    routerConfig: ref.watch(_router),
    locale: const Locale('ja'),
    supportedLocales: const [Locale('ja')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    debugShowCheckedModeBanner: false,
    theme: soramaruTheme(fontFamily: fontFamily),
  );
}
