import 'package:material_ui/material_ui.dart';

import 'design.dart';

enum ButtonKind { primary, secondary, outline, text, danger }

class ActionButton extends StatelessWidget {
  const ActionButton(
    this.label, {
    super.key,
    this.onPressed,
    this.kind = ButtonKind.primary,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final ButtonKind kind;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final background = switch (kind) {
      ButtonKind.primary => Palette.yellow,
      ButtonKind.secondary => Palette.warm,
      ButtonKind.danger => Palette.errorSurface,
      _ => Colors.transparent,
    };
    final foreground = switch (kind) {
      ButtonKind.danger => Palette.error,
      ButtonKind.text => Palette.link,
      _ => Palette.ink,
    };
    return TextButton(
      onPressed: loading ? null : onPressed,
      style: TextButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.padded,
        minimumSize: const Size(Space.touch, Space.touch),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.edge,
          vertical: Space.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Space.radius),
          side: kind == ButtonKind.outline
              ? const BorderSide(color: Palette.border)
              : BorderSide.none,
        ),
        backgroundColor: background,
        disabledBackgroundColor: Palette.disabled,
        foregroundColor: foreground,
        disabledForegroundColor: Palette.secondary,
      ),
      child: Wrap(
        spacing: Space.sm,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (loading && MediaQuery.disableAnimationsOf(context))
            const Icon(Icons.hourglass_empty, size: 18)
          else if (loading)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (icon != null)
            Icon(icon, size: 21),
          Text(loading ? '処理中…' : label, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class IconAction extends StatelessWidget {
  const IconAction(this.icon, this.label, {super.key, this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: label,
    constraints: const BoxConstraints.tightFor(
      width: Space.touch,
      height: Space.touch,
    ),
    icon: Icon(icon, size: 22),
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader(
    this.title, {
    super.key,
    this.leading,
    this.action,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.surface,
    child: Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Space.header),
          child: Padding(
            padding: EdgeInsets.only(
              left: leading == null ? Space.edge : Space.xs,
              right: Space.sm,
            ),
            child: Row(
              children: [
                ?leading,
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.sm),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: TypeStyles.caption.copyWith(
                              color: Palette.secondary,
                            ),
                          ),
                        Semantics(
                          header: true,
                          child: Text(title, style: TypeStyles.heading),
                        ),
                      ],
                    ),
                  ),
                ),
                ?action,
              ],
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1),
      ],
    ),
  );
}

enum CommunityTab {
  feed('ファン投稿', Icons.chat_bubble_outline, Icons.chat_bubble),
  content('コンテンツ', Icons.grid_view_outlined, Icons.grid_view_rounded),
  notifications('通知', Icons.notifications_none, Icons.notifications),
  profile('マイページ', Icons.person_outline, Icons.person),
  more('その他', Icons.more_horiz, Icons.more_horiz);

  const CommunityTab(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class CommunityBar extends StatelessWidget {
  const CommunityBar({
    super.key,
    required this.selected,
    required this.onSelect,
    this.unread = 0,
  });

  final CommunityTab selected;
  final ValueChanged<CommunityTab> onSelect;
  final int unread;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.surface,
    child: SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: Space.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, thickness: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Space.navigation),
            child: Row(
              children: [
                for (final item in CommunityTab.values)
                  Expanded(
                    child: _NavigationItem(
                      item: item,
                      selected: item == selected,
                      unread: item == CommunityTab.notifications ? unread : 0,
                      onPressed: () => onSelect(item),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.item,
    required this.selected,
    required this.unread,
    required this.onPressed,
  });

  final CommunityTab item;
  final bool selected;
  final int unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    selected: selected,
    button: true,
    label: unread > 0 ? '${item.label}、未読$unread件' : item.label,
    onTap: onPressed,
    excludeSemantics: true,
    child: InkWell(
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: Space.touch,
          minWidth: Space.touch,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: Space.xs,
            horizontal: 2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: unread > 0,
                backgroundColor: Palette.error,
                textColor: Palette.surface,
                label: Text(
                  unread > 99 ? '99+' : '$unread',
                  textScaler: TextScaler.noScaling,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? Palette.yellow : Palette.surface,
                    borderRadius: BorderRadius.circular(Space.radius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.sm,
                      vertical: Space.xs,
                    ),
                    child: Icon(
                      selected ? item.selectedIcon : item.icon,
                      size: 22,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                textAlign: TextAlign.center,
                style: TypeStyles.tab,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum FeedCategory {
  all('ALL', Icons.apps),
  artist('そらまる', Icons.wb_sunny_outlined),
  official('公式', Icons.verified_outlined),
  favorites('お気に入り', Icons.star_outline),
  tags('人気のタグ', Icons.tag);

  const FeedCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

class CategoryStrip extends StatelessWidget {
  const CategoryStrip({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final FeedCategory selected;
  final ValueChanged<FeedCategory> onSelect;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.surface,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final largeText = MediaQuery.textScalerOf(context).scale(12) > 16;
        final minCell = largeText ? 100.0 : 64.0;
        final available =
            (constraints.maxWidth - Space.edge * 2) /
            FeedCategory.values.length;
        final width = available
            .clamp(minCell, 92.0 < minCell ? minCell : 92.0)
            .toDouble();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.edge,
            vertical: Space.gap,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in FeedCategory.values)
                SizedBox(
                  width: width,
                  child: _CategoryButton(
                    item: item,
                    selected: item == selected,
                    onTap: () => onSelect(item),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _CategoryButton extends StatelessWidget {
  const _CategoryButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final FeedCategory item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    selected: selected,
    label: item.label,
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(Space.radius),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Palette.pink : Colors.transparent,
                border: Border.all(
                  color: selected ? Palette.pinkContrast : Colors.transparent,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Palette.gold,
                  ),
                  child: SizedBox.square(
                    dimension: Space.filter,
                    child: Icon(item.icon, size: 22),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.xs),
            Text(
              item.label,
              textAlign: TextAlign.center,
              style: TypeStyles.caption.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              height: 2,
              width: 19,
              child: ColoredBox(
                color: selected ? Palette.pinkContrast : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SectionTabs extends StatelessWidget {
  const SectionTabs(
    this.labels, {
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: Space.edge),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Semantics(
            selected: selected == i,
            child: TextButton(
              onPressed: () => onSelect(i),
              style: TextButton.styleFrom(
                foregroundColor: selected == i
                    ? Palette.link
                    : Palette.secondary,
                minimumSize: const Size(Space.touch, Space.touch),
                shape: const RoundedRectangleBorder(),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected == i ? Palette.link : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Space.xs),
                  child: Text(labels[i]),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class ComposeButton extends StatelessWidget {
  const ComposeButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      ActionButton('投稿する', icon: Icons.edit_outlined, onPressed: onPressed);
}
