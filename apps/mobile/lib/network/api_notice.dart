import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/controls.dart';
import '../ui/feedback.dart';
import 'api_client.dart';

ViewState? noticeFor(ApiIssue issue) => switch (issue) {
  ApiIssue.signIn => ViewState.signIn,
  ApiIssue.forbidden => ViewState.forbidden,
  ApiIssue.notFound => ViewState.removed,
  ApiIssue.rateLimited => ViewState.rateLimited,
  ApiIssue.maintenance => ViewState.maintenance,
  ApiIssue.budget => ViewState.budget,
  ApiIssue.network ||
  ApiIssue.unavailable ||
  ApiIssue.invalidResponse => ViewState.network,
  ApiIssue.cancelled => null,
};

final devApiProvider = Provider<ApiClient?>((ref) {
  const address = String.fromEnvironment('DEV_API_ORIGIN');
  if (!kDebugMode || address.isEmpty) return null;
  try {
    final client = ApiClient(Uri.parse(address));
    ref.onDispose(client.close);
    return client;
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
});

class DevApiPanel extends ConsumerStatefulWidget {
  const DevApiPanel({super.key});

  @override
  ConsumerState<DevApiPanel> createState() => _DevApiPanelState();
}

class _DevApiPanelState extends ConsumerState<DevApiPanel> {
  final _scope = ApiScope();
  ViewState? _notice;
  bool _ready = false;

  @override
  void dispose() {
    _scope.invalidate();
    super.dispose();
  }

  Future<void> _check(ApiClient client) async {
    setState(() {
      _notice = ViewState.loading;
      _ready = false;
    });
    try {
      await client.readiness(scope: _scope);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _notice = null;
      });
    } on ApiFailure catch (failure) {
      if (!mounted || failure.issue == ApiIssue.cancelled) return;
      setState(() => _notice = noticeFor(failure.issue));
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(devApiProvider);
    if (client == null) return const SizedBox.shrink();
    final notice = _notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ActionButton(
          '開発用サーバーの接続を確認',
          onPressed: notice == ViewState.loading ? null : () => _check(client),
        ),
        if (_ready)
          Semantics(liveRegion: true, child: const Text('接続を確認できました。')),
        if (notice != null) StateNotice(notice, compact: true),
      ],
    );
  }
}
