import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../community/community.dart';
import '../community/drafts.dart';
import '../photos/selection.dart';
import '../membership/controller.dart';
import '../preview/pages.dart' show ComposeDraft;
import '../ui/controls.dart';
import '../ui/design.dart';
import 'destinations.dart';
import 'ja.dart';
import 'pages.dart';
import 'sample_data.dart';
import 'session.dart';
import 'deep_links.dart';

class NavigationApp extends StatelessWidget {
  const NavigationApp({super.key, this.fontFamily});
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) {
      return MaterialApp(
        locale: const Locale('ja'),
        home: const Scaffold(body: Center(child: Text(Ja.preview))),
      );
    }
    return _NavigationRuntime(fontFamily: fontFamily);
  }
}

class _NavigationRuntime extends ConsumerWidget {
  const _NavigationRuntime({required this.fontFamily});
  final String? fontFamily;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navigation = ref.watch(navigationProvider);
    return MaterialApp.router(
      key: ValueKey(navigation.generation),
      title: Ja.preview,
      routerConfig: navigation.router,
      restorationScopeId: navigation.restorationId,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: soramaruTheme(fontFamily: fontFamily),
      debugShowCheckedModeBanner: false,
    );
  }
}

final initialExternalLinkProvider = Provider<String?>((ref) => null);
final navigationClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final navigationProvider = Provider<NavigationController>((ref) {
  final generation = ref.watch(
    demoSessionProvider.select((value) => value.generation),
  );
  final member = ref.read(membershipProvider);
  final drafts = ref.read(draftRepositoryProvider);
  final result = NavigationController(
    session: () => ref.read(demoSessionProvider),
    resources: ref.read(navigationResourcesProvider),
    now: ref.read(navigationClockProvider),
    generation: generation,
    realMembership: member,
    community: member == null || drafts == null
        ? null
        : Community(member, drafts),

    initialExternalLink: generation == 0
        ? ref.read(initialExternalLinkProvider)
        : null,
  );
  ref.listen(demoSessionProvider, (before, after) {
    if (after.generation != generation) return;
    if (before?.signedIn == false && after.signedIn) {
      result.resumeSignIn();
    } else {
      result.router.refresh();
    }
  });
  ref.onDispose(result.dispose);
  return result;
});

class NavigationController {
  NavigationController({
    required this._session,
    required this._resources,
    required this._now,
    required this.generation,
    String? initialExternalLink,
    this.realMembership,
    this.community,
  }) {
    final initial = initialExternalLink == null
        ? (realMembership == null ? Screen.feed.pattern : Screen.login.pattern)
        : _externalLocation(initialExternalLink);
    router = GoRouter(
      navigatorKey: _rootKey,
      initialLocation: initial,
      overridePlatformDefaultLocation: true,
      restorationScopeId: restorationId == null ? null : 'navigation-router',
      redirect: _redirect,
      errorPageBuilder: (context, state) => _page(
        context,
        state,
        BoundaryPage(navigation: this, screen: Screen.invalidLink),
      ),
      routes: [
        GoRoute(path: '/', redirect: (_, _) => Screen.feed.pattern),
        StatefulShellRoute.indexedStack(
          restorationScopeId: restorationId == null ? null : 'main-shell',
          pageBuilder: (context, state, shell) {
            _shell = shell;
            return NoTransitionPage(
              key: state.pageKey,
              restorationId: 'shell-page',
              child: _TabShell(navigation: this, shell: shell),
            );
          },
          branches: [
            for (final screen in Screen.tabs)
              StatefulShellBranch(
                navigatorKey: GlobalKey<NavigatorState>(),
                restorationScopeId: restorationId == null ? null : screen.id,
                routes: [_route(screen)],
              ),
          ],
        ),
        for (final screen in Screen.values.where(
          (screen) => screen.tab == null,
        ))
          _route(screen),
      ],
    );
  }

  final int generation;
  // After any demo account boundary, old OS buckets are detached.
  String? get restorationId => generation == 0 && realMembership == null
      ? 'soramaru-navigation-demo'
      : null;
  final MembershipController? realMembership;
  final Community? community;
  Draft? composing;
  List<String>? choosingTags;
  SelectionRequest? selectingPhotos;
  int albumPhotoIndex = 0;
  final _rootKey = GlobalKey<NavigatorState>();
  late final GoRouter router;
  StatefulNavigationShell? _shell;
  final DemoSession Function() _session;
  final NavigationResources _resources;
  final DateTime Function() _now;
  final _scroll = <CommunityTab, ScrollController>{};
  PendingDestination? _pending;
  final _return =
      ValueNotifier<({CommunityTab source, String destination, bool pushed})?>(
        null,
      );
  String? _queued;
  bool _disposed = false;
  String unavailableReason = Ja.missing;
  ComposeDraft? draft;
  final profileName = ValueNotifier('プレビュー会員');
  final badgeApplied = ValueNotifier(false);

  ScrollController scrollFor(CommunityTab tab) =>
      _scroll.putIfAbsent(tab, ScrollController.new);
  Screen? get current => Screen.byName[router.state.topRoute?.name];
  String get currentPath => router.state.uri.path;
  String get _currentLocation => router.state.uri.toString();

  void resolveComment(String post, String comment) {
    final location = Destination(Screen.comments, post, comment).location;
    final handoff = _return.value;
    if (handoff != null && handoff.destination == _currentLocation) {
      _return.value = (
        source: handoff.source,
        destination: location,
        pushed: handoff.pushed,
      );
    }
    router.replace(location);
  }

  void dispose() {
    community?.dispose();
    _disposed = true;
    router.dispose();
    draft = null;
    _return.dispose();
    profileName.dispose();
    badgeApplied.dispose();
    for (final item in _scroll.values) {
      item.dispose();
    }
  }

  GoRoute _route(Screen screen) => GoRoute(
    name: screen.name,
    path: screen.parent == null ? screen.pattern : screen.segment,
    parentNavigatorKey: screen.fullScreen && screen.tab != null
        ? _rootKey
        : null,
    pageBuilder: (context, state) {
      final id = state.pathParameters['id'];
      final normal = NavigationPage(
        navigation: this,
        screen: screen,
        resource: id,
        comment: screen == Screen.comments
            ? state.uri.queryParameters['comment']
            : null,
      );
      return _page(
        context,
        state,
        ValueListenableBuilder(
          valueListenable: _return,
          child: normal,
          builder: (context, handoff, child) {
            final returnsToSource =
                handoff?.destination == state.uri.toString();
            final branchRoot =
                screen == screen.root &&
                screen.tab != null &&
                screen != Screen.feed;
            return PopScope<Object?>(
              canPop: !returnsToSource && !branchRoot && screen != Screen.login,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop &&
                    (returnsToSource || branchRoot || screen == Screen.login)) {
                  back();
                }
              },
              child: child!,
            );
          },
        ),
        fullScreen: screen.fullScreen,
      );
    },
    routes: [
      for (final child in Screen.values.where(
        (child) => child.parent == screen,
      ))
        _route(child),
    ],
  );

  Page<Object?> _page(
    BuildContext context,
    GoRouterState state,
    Widget page, {
    bool fullScreen = false,
  }) {
    final id = 'route-${state.pageKey.value}';
    return MediaQuery.maybeOf(context)?.disableAnimations == true
        ? NoTransitionPage(key: state.pageKey, restorationId: id, child: page)
        : MaterialPage(
            key: state.pageKey,
            restorationId: id,
            fullscreenDialog: fullScreen,
            child: page,
          );
  }

  String? _redirect(BuildContext context, GoRouterState state) {
    final screen = Screen.byName[state.topRoute?.name];
    final focus = state.uri.queryParametersAll;
    final validFocus =
        community != null &&
        screen == Screen.comments &&
        focus.length == 1 &&
        focus['comment']?.length == 1 &&
        focus['comment']!.single.length == 36 &&
        resourceId.hasMatch(focus['comment']!.single);
    if ((state.uri.hasQuery && !validFocus) ||
        state.uri.hasFragment ||
        state.uri.hasScheme ||
        state.uri.hasAuthority) {
      return Screen.invalidLink.pattern;
    }
    if (screen == null) return null;
    if ((screen == Screen.login ||
            (screen == Screen.restricted && _pending != null)) &&
        _session().signedIn) {
      return _takePendingLocation() ?? Screen.feed.pattern;
    }
    return _blocked(screen, state.pathParameters['id']);
  }

  String? _takePendingLocation() {
    final pending = _pending;
    _pending = null;
    return pending != null && pending.valid(generation, _now())
        ? pending.destination.location
        : null;
  }

  void resumeSignIn() {
    router.go(_takePendingLocation() ?? Screen.feed.pattern);
  }

  String? _blocked(Screen screen, String? id) {
    final session = _session();
    if (screen.access != Access.public && !session.signedIn) {
      return session.canSignIn
          ? Screen.login.pattern
          : Screen.restricted.pattern;
    }
    if (screen.access == Access.artist && session.role != MemberRole.artist) {
      return Screen.restricted.pattern;
    }
    if (screen == Screen.device && realMembership != null) {
      return id != null && realMembership?.device(id) != null
          ? null
          : Screen.unavailable.pattern;
    }
    if (screen.hasResource) {
      if (id == null || !resourceId.hasMatch(id)) {
        return Screen.invalidLink.pattern;
      }
      if (community != null &&
          [
            Screen.post,
            Screen.comments,
            Screen.user,
            Screen.tagged,
            Screen.folder,
            if (community?.hasPhotos == true) ...[Screen.album, Screen.photo],
          ].contains(screen)) {
        return id.length == 36 ? null : Screen.unavailable.pattern;
      }
      final resource = _resources.statusOf(screen, id);
      if (resource != ResourceStatus.found) {
        unavailableReason = switch (resource) {
          ResourceStatus.deleted => Ja.removed,
          ResourceStatus.forbidden => Ja.privateContent,
          _ => Ja.missing,
        };
        return Screen.unavailable.pattern;
      }
    }
    return null;
  }

  String _externalLocation(String raw) {
    _pending = null;
    final destination = DeepLinks(
      _resources,
      community: community != null,
    ).parse(raw);
    if (destination == null) return Screen.invalidLink.pattern;
    final blocked = _blocked(destination.screen, destination.id);
    if (blocked == Screen.login.pattern ||
        (blocked == Screen.restricted.pattern &&
            (realMembership != null ||
                _session().status == SessionStatus.checking))) {
      _pending = PendingDestination(
        destination,
        generation,
        _now().add(const Duration(minutes: 5)),
      );
    }
    return blocked ?? destination.location;
  }

  /// Development ingress. Platform associations are deferred.
  bool receiveExternal(String raw) {
    if (current == Screen.compose ||
        current == Screen.pickPhoto ||
        current == Screen.pickTag) {
      return false;
    }
    final location = _externalLocation(raw);
    if (location == _currentLocation) {
      router.refresh();
    } else {
      final destination = DeepLinks(
        _resources,
        community: community != null,
      ).parse(raw);
      if (destination != null && location == destination.location) {
        open(destination);
      } else {
        _push<void>(location);
      }
    }
    return true;
  }

  Future<T?> open<T>(Destination destination) {
    final blocked = _blocked(destination.screen, destination.id);
    if (blocked != null) return _push<T>(blocked);
    final target = destination.screen.tab;
    final source = _activeTab;
    if (target == null ||
        source == target ||
        source == null ||
        _shell == null) {
      return _push<T>(destination.location);
    }
    if (_queued != null) return Future<T?>.value();
    return _crossTab<T>(source, target, destination.location);
  }

  CommunityTab? get _activeTab =>
      _shell == null ? null : CommunityTab.values[_shell!.currentIndex];

  Future<T?> _crossTab<T>(
    CommunityTab source,
    CommunityTab target,
    String path,
  ) async {
    _queued = path;
    _shell!.goBranch(target.index);
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed || _queued != path) return null;
    _queued = null;
    if (_activeTab != target) return null;
    final pushed = _currentLocation != path;
    _return.value = (source: source, destination: path, pushed: pushed);
    return pushed ? _push<T>(path) : null;
  }

  Future<T?> _push<T>(String location) {
    if (_disposed || _queued != null || _currentLocation == location) {
      return Future<T?>.value();
    }
    _queued = location;
    final result = router.push<T>(location);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_queued == location) _queued = null;
    });
    return result;
  }

  void select(CommunityTab tab) {
    final shell = _shell;
    if (shell == null || _queued != null) return;
    if (tab.index != shell.currentIndex) {
      _return.value = null;
      shell.goBranch(tab.index);
      return;
    }
    if (currentPath != Screen.tabs[tab.index].pattern) {
      _return.value = null;
      shell.goBranch(tab.index, initialLocation: true);
    } else {
      final controller = _scroll[tab];
      if (controller != null && controller.hasClients) controller.jumpTo(0);
    }
  }

  void cancelSignIn() {
    _pending = null;
    back();
  }

  void back<T>([T? value]) {
    if (current == Screen.login) _pending = null;
    final prior = _return.value;
    if (prior != null && prior.destination == _currentLocation) {
      _return.value = null;
      if (prior.pushed && router.canPop()) {
        router.pop<T>(value);
        _queued = prior.destination;
        // Let the target branch record its popped stack before hiding it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || _queued != prior.destination) return;
          _queued = null;
          _shell?.goBranch(prior.source.index);
        });
        WidgetsBinding.instance.scheduleFrame();
      } else {
        _shell?.goBranch(prior.source.index);
      }
      return;
    }
    if (router.canPop()) {
      router.pop<T>(value);
      return;
    }
    if (_activeTab != null && _activeTab != CommunityTab.feed) {
      _shell?.goBranch(CommunityTab.feed.index);
      return;
    }
    final fallback = (current?.recovery ?? Screen.feed).pattern;
    if (currentPath != fallback) router.go(fallback);
  }
}

class _TabShell extends StatelessWidget {
  const _TabShell({required this.navigation, required this.shell});

  final NavigationController navigation;
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: shell,
    bottomNavigationBar: CommunityBar(
      selected: CommunityTab.values[shell.currentIndex],
      unread: navigation.community == null
          ? sampleNotices.where((item) => item.unread).length
          : 0,
      onSelect: navigation.select,
    ),
  );
}
