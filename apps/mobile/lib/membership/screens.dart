import 'package:material_ui/material_ui.dart';

import '../navigation/ja.dart';
import '../ui/controls.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import 'controller.dart';
import 'gateway.dart';

enum _Mode { login, signup, reset, resetCode, newPassword, emailChange }

bool _email(String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim());
bool _password(String value) =>
    value.runes.length >= 12 && value.runes.length <= 128;
ViewState? _surface(String? code) => switch (code) {
  'maintenance' => ViewState.maintenance,
  'cost_limited' => ViewState.budget,
  'rate_limited' => ViewState.rateLimited,
  'unavailable' => ViewState.network,
  _ => null,
};

class MembershipGate extends StatefulWidget {
  const MembershipGate(this.account, {required this.onCancel, super.key});
  final MembershipController account;
  final VoidCallback onCancel;

  @override
  State<MembershipGate> createState() => _MembershipGateState();
}

class _MembershipGateState extends State<MembershipGate> {
  final _emailText = TextEditingController();
  final _passwordText = TextEditingController();
  final _confirmText = TextEditingController();
  final _code = TextEditingController();
  final _consents = <String>{};
  var _mode = _Mode.login;
  var _show = false;
  var _busy = false;
  var _continue = false;
  String? _notice;
  String? _error;

  @override
  void dispose() {
    for (final item in [_emailText, _passwordText, _confirmText, _code]) {
      item.dispose();
    }
    super.dispose();
  }

  void _select(_Mode mode) => setState(() {
    _mode = mode;
    _notice = null;
    _error = null;
    _passwordText.clear();
    _confirmText.clear();
    if (mode == _Mode.login) _code.clear();
  });

  Future<void> _run(
    Future<void> Function() action, {
    String? confirmation,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (confirmation != null) setState(() => _notice = confirmation);
    } on MembershipFailure catch (error) {
      if (!mounted || error.code == 'cancelled') return;
      setState(() {
        _error = error.code;
        _notice = error.message;
      });
    } on Exception {
      if (mounted) setState(() => _error = 'unavailable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    final account = widget.account;
    _run(() async {
      final mail = _emailText.text.trim();
      final password = _passwordText.text;
      switch (_mode) {
        case _Mode.login:
        case _Mode.signup:
          final signup = _mode == _Mode.signup;
          if (!_email(mail) ||
              password.isEmpty ||
              signup &&
                  (!_password(password) ||
                      password != _confirmText.text ||
                      _consents.length != 3)) {
            throw const MembershipFailure('invalid_request');
          }
          _continue = false;
          try {
            await account.signIn(mail, password, signup: signup);
            _passwordText.clear();
            _confirmText.clear();
          } on MembershipFailure catch (error) {
            if (_surface(error.code) != null) _continue = true;
            rethrow;
          }
          if (signup && account.phase == MemberPhase.unverified) {
            await account.sendVerification();
          }
        case _Mode.reset:
          if (!_email(mail)) throw const MembershipFailure('invalid_request');
          await account.sendReset(mail);
          if (mounted) _select(_Mode.resetCode);
        case _Mode.resetCode:
          await account.resetPassword(_code.text.trim());
          if (mounted) _select(_Mode.newPassword);
        case _Mode.newPassword:
          if (!_password(password) || password != _confirmText.text) {
            throw const MembershipFailure('invalid_request');
          }
          await account.resetPassword(_code.text.trim(), password: password);
          if (mounted) {
            _select(_Mode.login);
            setState(() => _notice = 'パスワードを再設定しました。ログインしてください。');
          }
        case _Mode.emailChange:
          if (!_email(mail)) throw const MembershipFailure('invalid_request');
          await account.changeEmail(mail);
          if (mounted) _select(_Mode.login);
      }
    });
  }

  Widget _action(String text, VoidCallback action, {bool secondary = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: Space.gap),
        child: ActionButton(
          text,
          onPressed: _busy ? null : action,
          kind: secondary ? ButtonKind.outline : ButtonKind.primary,
        ),
      );

  Widget _passwordField(
    TextEditingController controller,
    String label,
    bool signup,
  ) => TextField(
    controller: controller,
    enabled: !_busy,
    obscureText: !_show,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: [
      signup ? AutofillHints.newPassword : AutofillHints.password,
    ],
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        tooltip: _show ? 'パスワードを隠す' : 'パスワードを表示',
        onPressed: () => setState(() => _show = !_show),
        icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
      ),
    ),
  );

  List<Widget> _form() {
    final mail = {
      _Mode.login,
      _Mode.signup,
      _Mode.reset,
      _Mode.emailChange,
    }.contains(_mode);
    final pw = {_Mode.login, _Mode.signup, _Mode.newPassword}.contains(_mode);
    final confirm = {_Mode.signup, _Mode.newPassword}.contains(_mode);
    final title = switch (_mode) {
      _Mode.login => 'ログイン',
      _Mode.signup => '新規会員登録',
      _Mode.reset => 'パスワードの再設定',
      _Mode.resetCode => '再設定コードの確認',
      _Mode.newPassword => '新しいパスワード',
      _Mode.emailChange => 'メールアドレスを変更する',
    };
    return [
      Text(title, style: TypeStyles.heading),
      const SizedBox(height: Space.gap),
      if (_mode == _Mode.resetCode)
        const Text('該当するアカウントがある場合は、再設定の案内が届きます。開発用コードを入力してください。'),
      AutofillGroup(
        child: Column(
          children: [
            if (mail)
              TextField(
                controller: _emailText,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'メールアドレス'),
              ),
            if (pw) ...[
              const SizedBox(height: Space.gap),
              _passwordField(
                _passwordText,
                confirm ? '新しいパスワード' : 'パスワード',
                confirm,
              ),
            ],
            if (confirm) ...[
              const SizedBox(height: Space.gap),
              _passwordField(_confirmText, 'パスワード（確認）', true),
              const Text('12文字以上、128文字以内で入力してください。'),
            ],
            if (_mode == _Mode.resetCode)
              TextField(
                controller: _code,
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '再設定コード'),
              ),
          ],
        ),
      ),
      if (_mode == _Mode.signup) ...[
        for (final pair in const [
          ('terms', '利用規約への同意'),
          ('privacy', 'プライバシーポリシーの確認'),
          ('guidelines', 'コミュニティガイドラインへの同意'),
        ])
          CheckboxListTile(
            title: Text(pair.$2),
            value: _consents.contains(pair.$1),
            onChanged: _busy
                ? null
                : (checked) => setState(() {
                    if (checked == true) {
                      _consents.add(pair.$1);
                    } else {
                      _consents.remove(pair.$1);
                    }
                  }),
          ),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('開発用の文書'),
              content: SingleChildScrollView(child: PolicyCopy(widget.account)),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).pop(),
                  child: const Text('閉じる'),
                ),
              ],
            ),
          ),
          child: const Text('文書を読む'),
        ),
      ],
      _action(switch (_mode) {
        _Mode.login => 'ログイン',
        _Mode.signup => '登録する',
        _Mode.reset => '再設定の案内を送る',
        _Mode.resetCode => 'コードを確認',
        _Mode.newPassword => 'パスワードを変更',
        _Mode.emailChange => '変更する',
      }, _submit),
      if (_mode == _Mode.login) ...[
        _action('新規会員登録', () => _select(_Mode.signup), secondary: true),
        _action('パスワードをお忘れですか？', () => _select(_Mode.reset), secondary: true),
        if (_continue)
          _action(
            '会員登録を続ける',
            () => _run(widget.account.finishSignIn),
            secondary: true,
          ),
      ] else if (_mode != _Mode.emailChange)
        _action('ログイン画面へ戻る', () => _select(_Mode.login), secondary: true),
      if (_mode == _Mode.resetCode)
        _action('再設定の案内を再送する', () => _select(_Mode.reset), secondary: true),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.account,
    builder: (context, _) {
      final account = widget.account;
      return ListView(
        padding: const EdgeInsets.all(Space.edge),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_surface(_error) case final notice?) StateNotice(notice),
          if (_notice case final notice?)
            Semantics(liveRegion: true, child: Text(notice)),
          switch (account.phase) {
            MemberPhase.starting => const StateNotice(ViewState.loading),
            MemberPhase.offline => StateNotice(
              ViewState.network,
              onRetry: () => _run(account.restore),
            ),
            MemberPhase.suspended => const Text('このアカウントの利用は停止されています。'),
            MemberPhase.deleting => const Text('アカウントの削除手続き中です。'),
            MemberPhase.terms => PolicyConsent(account),
            MemberPhase.profile => MemberEditor(account, onSaved: () {}),
            MemberPhase.unverified when _mode != _Mode.emailChange => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('メールアドレスの確認', style: TypeStyles.heading),
                const Text('確認リンクを開いた後、「確認しました」を選んでください。開発用コードも入力できます。'),
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '確認コード（開発用）'),
                ),
                _action(
                  '確認しました',
                  () => _run(() => account.verifyEmail(_code.text.trim())),
                ),
                _action(
                  '確認メールを再送する',
                  () => _run(
                    account.sendVerification,
                    confirmation: '確認の案内を受け付けました。',
                  ),
                  secondary: true,
                ),
                _action(
                  'メールアドレスを変更する',
                  () => _select(_Mode.emailChange),
                  secondary: true,
                ),
                _action(
                  'ログイン画面に戻る',
                  () => _run(account.signOut),
                  secondary: true,
                ),
              ],
            ),
            _ => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (account.phase == MemberPhase.expired)
                  const StateNotice(ViewState.signIn),
                ..._form(),
              ],
            ),
          },
          if ([
            MemberPhase.terms,
            MemberPhase.profile,
            MemberPhase.offline,
          ].contains(account.phase))
            _action('ログアウト', () => _run(account.signOut), secondary: true),
          _action('戻る', widget.onCancel, secondary: true),
        ],
      );
    },
  );
}

class PolicyCopy extends StatefulWidget {
  const PolicyCopy(this.account, {this.kind, super.key});
  final MembershipController account;
  final String? kind;
  @override
  State<PolicyCopy> createState() => _PolicyCopyState();
}

class _PolicyCopyState extends State<PolicyCopy> {
  late final _copy = widget.account.policies();

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: _copy,
    builder: (context, view) => view.hasError
        ? const StateNotice(ViewState.network)
        : !view.hasData
        ? const StateNotice(ViewState.loading)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('開発用の仮文書です。'),
              for (final doc
                  in (view.data?['documents'] as List? ?? const [])
                      .whereType<Json>())
                if (widget.kind == null || doc['kind'] == widget.kind) ...[
                  const SizedBox(height: Space.gap),
                  Text(
                    doc['title'] as String? ?? '',
                    style: TypeStyles.heading,
                  ),
                  Text(doc['text'] as String? ?? ''),
                ],
            ],
          ),
  );
}

class PolicyConsent extends StatefulWidget {
  const PolicyConsent(this.account, {super.key});
  final MembershipController account;
  @override
  State<PolicyConsent> createState() => _PolicyConsentState();
}

class _PolicyConsentState extends State<PolicyConsent> {
  final _checked = <String>{};
  late final _policies = widget.account.policies();
  bool _busy = false;
  String? _failure;

  Future<void> _save(String version) async {
    setState(() => _busy = true);
    try {
      await widget.account.accept(version);
    } on MembershipFailure catch (error) {
      if (mounted) setState(() => _failure = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: _policies,
    builder: (context, view) {
      final data = view.data;
      if (view.hasError) return const StateNotice(ViewState.network);
      if (data == null) return const StateNotice(ViewState.loading);
      final documents = (data['documents'] as List? ?? const [])
          .whereType<Json>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('利用規約への同意', style: TypeStyles.heading),
          const Text('開発用の仮文書です。最新版をご確認ください。'),
          for (final doc in documents)
            CheckboxListTile(
              value: _checked.contains(doc['kind']),
              title: Text(doc['title'] as String),
              subtitle: Text(doc['text'] as String),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      final kind = doc['kind'] as String;
                      if (value == true) {
                        _checked.add(kind);
                      } else {
                        _checked.remove(kind);
                      }
                    }),
            ),
          if (_failure case final message?)
            Semantics(liveRegion: true, child: Text(message)),
          ActionButton(
            '確認して同意する',
            onPressed: _busy || _checked.length != 3
                ? null
                : () => _save(data['version'] as String),
          ),
        ],
      );
    },
  );
}

class MemberEditor extends StatefulWidget {
  const MemberEditor(this.account, {required this.onSaved, super.key});
  final MembershipController account;
  final VoidCallback onSaved;
  @override
  State<MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<MemberEditor> {
  late final Json _profile = widget.account.profile ?? const {};
  late final _nickname = TextEditingController(
    text: _profile['nickname'] as String? ?? '',
  );
  late final _bio = TextEditingController(
    text: _profile['biography'] as String? ?? '',
  );
  late final _month = TextEditingController(
    text: _profile['birthMonth']?.toString() ?? '',
  );
  late final _day = TextEditingController(
    text: _profile['birthDay']?.toString() ?? '',
  );
  late bool _public = _profile['collectionPublic'] == true;
  bool _busy = false;
  String? _failure;

  @override
  void dispose() {
    for (final field in [_nickname, _bio, _month, _day]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final nick = _nickname.text.trim();
      final bio = _bio.text.trim();
      final month = int.tryParse(_month.text);
      final day = int.tryParse(_day.text);
      if (nick.isEmpty ||
          nick.runes.length > 32 ||
          bio.runes.length > 500 ||
          (_month.text.isNotEmpty || _day.text.isNotEmpty) &&
              (month == null || day == null)) {
        throw const MembershipFailure('invalid_request');
      }
      await widget.account.edit({
        'nickname': nick,
        'biography': bio,
        'birthMonth': month,
        'birthDay': day,
        'avatarMediaId': _profile['avatarMediaId'],
        'collectionPublic': _public,
      }, _profile['version'] as int);
      if (mounted) widget.onSaved();
    } on MembershipFailure catch (error) {
      if (mounted) setState(() => _failure = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.account.phase == MemberPhase.profile)
        const Text('プロフィール設定', style: TypeStyles.heading),
      TextField(
        controller: _nickname,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: 'ニックネーム',
          helperText: '1〜32文字',
        ),
      ),
      const SizedBox(height: Space.gap),
      TextField(
        controller: _bio,
        enabled: !_busy,
        maxLines: 3,
        decoration: const InputDecoration(
          labelText: '自己紹介',
          helperText: '500文字以内',
        ),
      ),
      const SizedBox(height: Space.gap),
      const Text('誕生日（任意）'),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _month,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '月'),
            ),
          ),
          const SizedBox(width: Space.gap),
          Expanded(
            child: TextField(
              controller: _day,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '日'),
            ),
          ),
        ],
      ),
      SwitchListTile(
        value: _public,
        title: const Text('コレクションを公開する'),
        onChanged: _busy ? null : (value) => setState(() => _public = value),
      ),
      if (_failure case final message?)
        Semantics(liveRegion: true, child: Text(message)),
      ActionButton('保存する', onPressed: _busy ? null : _save),
    ],
  );
}

Future<bool> confirmSignOut(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: const Text('選択した端末のセッションを終了します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    ) ??
    false;

class DevicesPane extends StatefulWidget {
  const DevicesPane(this.account, {required this.open, this.alias, super.key});
  final MembershipController account;
  final ValueChanged<String> open;
  final String? alias;

  @override
  State<DevicesPane> createState() => _DevicesPaneState();
}

class _DevicesPaneState extends State<DevicesPane> {
  late Future<Object> _request = _load();

  Future<Object> _load() {
    final alias = widget.alias;
    return alias == null
        ? widget.account.listDevices()
        : widget.account.deviceDetail(alias);
  }

  Future<void> _revoke(String? alias) async {
    if (!await confirmSignOut(
          context,
          alias == null ? 'すべての端末からログアウト' : 'この端末からログアウト',
        ) ||
        !mounted) {
      return;
    }
    try {
      if (alias == null) {
        await widget.account.signOut(all: true);
      } else {
        await widget.account.revokeDevice(alias);
      }
      if (mounted) setState(() => _request = _load());
    } on MembershipFailure catch (error) {
      if (mounted) setState(() => _request = Future<Object>.error(error));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Object>(
    future: _request,
    builder: (context, view) {
      if (view.hasError) {
        final error = view.error;
        return Column(
          children: [
            Text(error is MembershipFailure ? error.message : '接続できませんでした。'),
            ActionButton(
              '再試行',
              onPressed: () => setState(() => _request = _load()),
            ),
          ],
        );
      }
      final data = view.data;
      if (data == null) return const StateNotice(ViewState.loading);
      if (data is List<String>) {
        return Column(
          children: [
            for (final alias in data)
              ListTile(
                title: Text(
                  widget.account.device(alias)?['alias'] as String? ?? '端末',
                ),
                subtitle: Text(
                  widget.account.device(alias)?['current'] == true
                      ? '現在の端末'
                      : '登録済みの端末',
                ),
                onTap: () => widget.open(alias),
              ),
            ActionButton(
              'すべての端末からログアウト',
              kind: ButtonKind.outline,
              onPressed: () => _revoke(null),
            ),
          ],
        );
      }
      final device = data as Json;
      String date(String key) => Ja.date(
        DateTime.fromMillisecondsSinceEpoch(device[key] as int, isUtc: true),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(device['alias'] as String, style: TypeStyles.heading),
          Text(device['os'] as String),
          Text(device['current'] == true ? '現在の端末' : '登録済みの端末'),
          Text('初回ログイン　${date('createdAt')}'),
          Text('最近の利用　${date('lastSeen')}'),
          Text(switch (device['status']) {
            'active' => '利用中',
            'expired' => '期限切れ',
            _ => 'ログアウト済み',
          }),
          ActionButton(
            'この端末からログアウト',
            onPressed: device['status'] == 'active'
                ? () => _revoke(widget.alias)
                : null,
          ),
        ],
      );
    },
  );
}
