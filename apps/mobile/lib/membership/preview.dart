import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../community/drafts.dart';
import '../navigation/navigation_app.dart';
import '../navigation/session.dart';
import 'controller.dart';
import 'gateway.dart';

class MembershipPreview extends StatefulWidget {
  const MembershipPreview({super.key});
  @override
  State<MembershipPreview> createState() => _MembershipPreviewState();
}

class _MembershipPreviewState extends State<MembershipPreview> {
  MembershipController? _controller;
  DraftRepository? _drafts;

  @override
  void initState() {
    super.initState();
    if (!kDebugMode) return;
    const setting = String.fromEnvironment('DEV_MEMBERSHIP_HOST');
    final defaultHost = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : '127.0.0.1';
    try {
      final drafts = DraftRepository.local();
      _drafts = drafts;
      final value = MembershipController(
        LoopbackMembership(setting.isEmpty ? defaultHost : setting),
        OSVault(),
        purgeDrafts: drafts.purge,
        hasDrafts: (owner) async => (await drafts.list(owner)).isNotEmpty,
      );
      _controller = value;
      unawaited(value.restore());
    } on ArgumentError {
      return;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    if (_drafts case final drafts?) unawaited(drafts.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: Text('開発用の接続設定をご確認ください。'))),
      );
    }
    return ProviderScope(
      overrides: [
        membershipProvider.overrideWithValue(controller),
        draftRepositoryProvider.overrideWithValue(_drafts),
        demoSessionProvider.overrideWith(() => EmulatorIdentity(controller)),
      ],
      child: const NavigationApp(),
    );
  }
}
