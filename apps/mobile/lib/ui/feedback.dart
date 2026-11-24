import 'package:material_ui/material_ui.dart';

import 'controls.dart';
import 'design.dart';

enum ViewState {
  loading('読み込み中', 'コンテンツを読み込んでいます。', Icons.hourglass_empty),
  skeleton('準備中', '一覧を読み込んでいます。', Icons.view_agenda_outlined),
  refreshing('更新中', '新しい情報を確認しています。', Icons.refresh),
  empty('まだ投稿がありません', '新しい投稿が届くと、ここに表示されます。', Icons.inbox_outlined),
  noResults('検索結果が見つかりません', '別のキーワードで検索してください。', Icons.search_off),
  network('読み込めませんでした', '通信状況を確認して、もう一度お試しください。', Icons.cloud_off),
  offline('オフラインです', '接続が戻るまで、表示済みの内容をご覧いただけます。', Icons.wifi_off),
  signIn('ログインし直してください', 'ログインの有効期限が切れました。', Icons.login),
  forbidden('このページは表示できません', 'この内容を閲覧する権限がありません。', Icons.lock_outline),
  uploadLimit('添付できる上限に達しました', '添付を減らしてから、もう一度お試しください。', Icons.attach_file),
  budget(
    '一部の機能を一時停止しています',
    '利用上限に達したため、時間をおいてお試しください。',
    Icons.pause_circle_outline,
  ),
  removed('このコンテンツは削除されました', '一覧に戻って、ほかのコンテンツをご覧ください。', Icons.delete_outline),
  maintenance('メンテナンス中です', 'しばらくしてから、もう一度ご確認ください。', Icons.build_outlined);

  const ViewState(this.title, this.message, this.icon);
  final String title;
  final String message;
  final IconData icon;
}

class StateNotice extends StatelessWidget {
  const StateNotice(
    this.status, {
    super.key,
    this.onRetry,
    this.compact = false,
  });

  final ViewState status;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isError = status == ViewState.network;
    final textColor = isError ? Palette.error : Palette.warning;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final indicator =
        status == ViewState.loading || status == ViewState.refreshing;
    final skeleton = status == ViewState.skeleton;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isError ? Palette.errorSurface : Palette.warm,
          borderRadius: BorderRadius.circular(Space.radius),
        ),
        child: Padding(
          padding: EdgeInsets.all(compact ? Space.gap : Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (indicator && !reducedMotion)
                const SizedBox.square(
                  dimension: 22,
                  child: ExcludeSemantics(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Icon(status.icon, color: textColor, semanticLabel: null),
              const SizedBox(height: Space.sm),
              Text(
                status.title,
                style: TypeStyles.heading.copyWith(color: textColor),
              ),
              Text(status.message),
              if (skeleton)
                const ExcludeSemantics(
                  child: Padding(
                    padding: EdgeInsets.only(top: Space.edge),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkeletonLine(fraction: 1),
                        SizedBox(height: Space.sm),
                        _SkeletonLine(fraction: .65),
                        SizedBox(height: Space.sm),
                        _SkeletonLine(fraction: .8),
                      ],
                    ),
                  ),
                ),
              if (onRetry != null) ...[
                const SizedBox(height: Space.gap),
                ActionButton(
                  status == ViewState.signIn ? 'ログイン' : '再試行',
                  onPressed: onRetry,
                  kind: ButtonKind.outline,
                  icon: status == ViewState.signIn ? null : Icons.refresh,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: fraction,
    child: const SizedBox(
      height: 12,
      child: ColoredBox(color: Palette.disabled),
    ),
  );
}

class InputField extends StatelessWidget {
  const InputField(
    this.label, {
    super.key,
    this.controller,
    this.hint,
    this.maxLength,
    this.multiline = false,
    this.search = false,
    this.onChanged,
  });
  final String label;
  final TextEditingController? controller;
  final String? hint;
  final int? maxLength;
  final bool multiline;
  final bool search;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    minLines: multiline ? 4 : 1,
    maxLines: multiline ? 8 : 1,
    maxLength: maxLength,
    keyboardType: multiline
        ? TextInputType.multiline
        : search
        ? TextInputType.text
        : null,
    textInputAction: search
        ? TextInputAction.search
        : multiline
        ? TextInputAction.newline
        : null,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: search ? const Icon(Icons.search) : null,
    ),
  );
}

class SettingsRow extends StatelessWidget {
  const SettingsRow(
    this.title, {
    super.key,
    this.icon,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Material(
        color: Palette.surface,
        child: ListTile(
          minTileHeight: Space.touch,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Space.edge,
            vertical: Space.xs,
          ),
          leading: icon == null ? null : Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing:
              trailing ??
              (onTap != null ? const Icon(Icons.chevron_right) : null),
          onTap: onTap,
        ),
      ),
      const Divider(height: 1, thickness: 1),
    ],
  );
}

class AttachmentButton extends StatelessWidget {
  const AttachmentButton({
    super.key,
    required this.count,
    required this.limit,
    this.onPressed,
  });
  final int count;
  final int limit;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ActionButton(
    '画像を追加 ($count/$limit)',
    icon: Icons.add_photo_alternate_outlined,
    kind: ButtonKind.outline,
    onPressed: count >= limit ? null : onPressed,
  );
}

class TagChip extends StatelessWidget {
  const TagChip(this.tag, {super.key, this.onRemove});
  final String tag;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => InputChip(
    label: Text('#$tag'),
    onDeleted: onRemove,
    deleteButtonTooltipMessage: 'タグを削除',
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool destructive = false,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('戻る'),
            ),
            ActionButton(
              action,
              kind: destructive ? ButtonKind.danger : ButtonKind.primary,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> showActions(
  BuildContext context,
  String title,
  List<Widget> items,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: Space.gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PageHeader(
            title,
            action: IconAction(
              Icons.close,
              '閉じる',
              onPressed: () => Navigator.pop(context),
            ),
          ),
          ...items,
        ],
      ),
    ),
  ),
);

void showNotice(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
