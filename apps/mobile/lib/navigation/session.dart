import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ja.dart';

enum SessionStatus {
  checking,
  signedOut,
  member,
  unverified,
  termsRequired,
  expired,
  suspended,
  deleting,
}

enum MemberRole { member, artist, administrator }

class DemoSession {
  const DemoSession({
    this.status = SessionStatus.member,
    this.role = MemberRole.member,
    this.account = 'demo-a',
    this.generation = 0,
  });

  final SessionStatus status;
  final MemberRole role;
  final String? account;
  final int generation;

  bool get signedIn => status == SessionStatus.member && account != null;
  bool get canSignIn =>
      status == SessionStatus.signedOut || status == SessionStatus.expired;

  String get explanation => switch (status) {
    SessionStatus.checking => Ja.loading,
    SessionStatus.signedOut => Ja.memberOnly,
    SessionStatus.member => Ja.roleOnly,
    SessionStatus.unverified => Ja.verifyEmail,
    SessionStatus.termsRequired => Ja.reviewTerms,
    SessionStatus.expired => Ja.sessionExpired,
    SessionStatus.suspended => Ja.accountSuspended,
    SessionStatus.deleting => Ja.accountDeleting,
  };
}

final demoSessionProvider = NotifierProvider<DemoIdentity, DemoSession>(
  DemoIdentity.new,
);

class DemoIdentity extends Notifier<DemoSession> {
  @override
  DemoSession build() => const DemoSession();

  void change(
    SessionStatus status, {
    MemberRole role = MemberRole.member,
    String? account,
  }) {
    final previous = state;
    final nextAccount = status == SessionStatus.member
        ? account ?? 'demo-a'
        : account;
    final clearsNavigation =
        previous.account != null &&
        (status != SessionStatus.member ||
            previous.account != nextAccount ||
            previous.role != role);
    state = DemoSession(
      status: status,
      role: role,
      account: nextAccount,
      generation: previous.generation + (clearsNavigation ? 1 : 0),
    );
  }
}
