import 'package:material_ui/material_ui.dart';

import 'controls.dart';
import 'design.dart';

enum CoverScene { morning, coast, evening, garden }

/// Original geometric artwork for local previews. Uses no raster or network assets.
class CoverArt extends StatelessWidget {
  const CoverArt(this.scene, {super.key, this.ratio = 16 / 9});
  final CoverScene scene;
  final double ratio;

  @override
  Widget build(BuildContext context) =>
      MediaFrame(ratio: ratio, child: Landscape(scene));
}

class MediaFrame extends StatelessWidget {
  const MediaFrame({super.key, required this.ratio, required this.child});
  final double ratio;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Space.radius),
    child: AspectRatio(aspectRatio: ratio, child: child),
  );
}

class Landscape extends StatelessWidget {
  const Landscape(this.scene, {super.key});
  final CoverScene scene;

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: CustomPaint(painter: _LandscapePainter(scene)));
}

class _LandscapePainter extends CustomPainter {
  const _LandscapePainter(this.scene);
  final CoverScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final (paper, sun, far, near, foreground, line) = switch (scene) {
      CoverScene.morning => (
        const Color(0xFFF6DBA7),
        const Color(0xFFF7AF45),
        const Color(0xFFCD835E),
        const Color(0xFF736F59),
        const Color(0xFF354A44),
        const Color(0xFFFFDF9F),
      ),
      CoverScene.coast => (
        const Color(0xFFD1E6E8),
        const Color(0xFFF0B368),
        const Color(0xFF85A5AF),
        const Color(0xFF4A798C),
        const Color(0xFF2D5262),
        const Color(0xFFC9EBE4),
      ),
      CoverScene.evening => (
        const Color(0xFFE3C1C5),
        const Color(0xFFFFD0A0),
        const Color(0xFFAD829A),
        const Color(0xFF745E80),
        const Color(0xFF3C415F),
        const Color(0xFFF5C7BA),
      ),
      CoverScene.garden => (
        const Color(0xFFE7E5AD),
        const Color(0xFFF7BD70),
        const Color(0xFFA2AB72),
        const Color(0xFF648069),
        const Color(0xFF354F4A),
        const Color(0xFFFFDA99),
      ),
    };
    final paint = Paint()..color = paper;
    final w = size.width;
    final h = size.height;
    canvas.drawRect(Offset.zero & size, paint);
    canvas.drawCircle(
      Offset(w * .72, h * .33),
      size.shortestSide * .18,
      paint..color = sun,
    );
    for (final (index, offset) in [.26, .10, -.08].indexed) {
      final ridge = Path()
        ..moveTo(0, h * (.88 - offset))
        ..cubicTo(
          w * .25,
          h * (.28 + offset),
          w * .4,
          h * (.56 - offset),
          w * .54,
          h * (.66 - offset),
        )
        ..cubicTo(
          w * .72,
          h * (.79 - offset),
          w * .91,
          h * (.54 - offset),
          w,
          h * (.62 - offset),
        )
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(ridge, paint..color = [far, near, foreground][index]);
    }
    paint
      ..color = line
      ..strokeWidth = 1.25
      ..style = PaintingStyle.stroke;
    final trail = Path()
      ..moveTo(w * .09, h)
      ..quadraticBezierTo(w * .7, h * .82, w * .42, h * .79)
      ..quadraticBezierTo(w * .32, h * .76, w * .55, h * .72);
    canvas.drawPath(trail, paint);
    for (var i = 0; i < 3; i++) {
      canvas.drawLine(
        Offset(w * (.12 + i * .03), h * .15),
        Offset(w * (.18 + i * .03), h * .15),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LandscapePainter oldDelegate) =>
      oldDelegate.scene != scene;
}

class AvatarMark extends StatelessWidget {
  const AvatarMark({
    super.key,
    this.icon = Icons.emoji_nature_outlined,
    this.badge = false,
    this.size = 42,
  });
  final IconData icon;
  final bool badge;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: size / 2,
          backgroundColor: Palette.warm,
          foregroundColor: Palette.warning,
          child: Icon(icon, size: size * .50),
        ),
        if (badge)
          const Positioned(
            bottom: -2,
            right: -2,
            child: CircleAvatar(
              radius: 9,
              backgroundColor: Palette.surface,
              child: Icon(Icons.verified, size: 15, color: Palette.link),
            ),
          ),
      ],
    ),
  );
}

class InfoTag extends StatelessWidget {
  const InfoTag(
    this.label, {
    super.key,
    this.background = Palette.warm,
    this.foreground = Palette.warning,
  });
  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: Space.sm,
      vertical: Space.xs,
    ),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(Space.sm),
    ),
    child: Text(
      label,
      style: TypeStyles.caption.copyWith(
        color: foreground,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class FeedPost {
  const FeedPost({
    required this.author,
    required this.time,
    required this.body,
    this.tags = const [],
    this.photos = const [],
    this.likes = 0,
    this.comments = 0,
    this.official = false,
    this.pinned = false,
    this.liked = false,
  });

  final String author;
  final String time;
  final String body;
  final List<String> tags;
  final List<Widget> photos;
  final int likes;
  final int comments;
  final bool official;
  final bool pinned;
  final bool liked;
}

class PostCard extends StatelessWidget {
  const PostCard(
    this.post, {
    super.key,
    this.onOpen,
    this.onLike,
    this.onAuthor,
    this.officialLabel = '公式サンプル',
    this.showReactionCounts = true,
    this.onComment,
    this.onShare,
    this.onMore,
  });
  final FeedPost post;
  final VoidCallback? onOpen;
  final VoidCallback? onLike;
  final VoidCallback? onAuthor;
  final String officialLabel;
  final bool showReactionCounts;
  final VoidCallback? onComment;
  final VoidCallback? onShare;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Palette.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.edge,
            Space.edge,
            Space.edge,
            Space.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (post.pinned) ...[
                const InfoTag('固定のお知らせ'),
                const SizedBox(height: Space.gap),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AvatarMark(
                    badge: post.official,
                    icon: post.official
                        ? Icons.wb_sunny_outlined
                        : Icons.eco_outlined,
                  ),
                  const SizedBox(width: Space.gap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: Space.sm,
                          runSpacing: Space.xs,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              post.author,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (post.official)
                              const InfoTag(
                                '公式サンプル',
                                background: Palette.mutedBlue,
                                foreground: Palette.link,
                              ),
                          ],
                        ),
                        Text(
                          post.time,
                          style: TypeStyles.caption.copyWith(
                            color: Palette.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.gap),
              if (onOpen == null)
                Text(post.body)
              else
                Semantics(
                  button: true,
                  child: InkWell(
                    onTap: onOpen,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: Space.touch),
                      child: Text(post.body),
                    ),
                  ),
                ),
              if (post.tags.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.xs,
                  children: [
                    for (final tag in post.tags)
                      Text(
                        '#$tag',
                        style: TypeStyles.caption.copyWith(color: Palette.link),
                      ),
                  ],
                ),
              ],
              if (post.photos.isNotEmpty) ...[
                const SizedBox(height: Space.gap),
                if (post.photos.length == 1)
                  Semantics(
                    image: true,
                    label: '風景イラスト',
                    child: MediaFrame(ratio: 16 / 9, child: post.photos.first),
                  )
                else
                  Row(
                    children: [
                      for (final (index, scene)
                          in post.photos.take(3).indexed) ...[
                        if (index > 0) const SizedBox(width: Space.sm),
                        Expanded(
                          child: Semantics(
                            image: true,
                            label: '風景イラスト ${index + 1}',
                            child: MediaFrame(ratio: 1, child: scene),
                          ),
                        ),
                      ],
                    ],
                  ),
              ],
              const SizedBox(height: Space.xs),
              Wrap(
                spacing: Space.sm,
                children: [
                  if (showReactionCounts)
                    _Reaction(
                      icon: post.liked ? Icons.favorite : Icons.favorite_border,
                      label: 'いいね',
                      count: post.likes,
                      selected: post.liked,
                      onPressed: onLike,
                    ),
                  if (showReactionCounts)
                    _Reaction(
                      icon: Icons.chat_bubble_outline,
                      label: 'コメント',
                      count: post.comments,
                      onPressed: onComment,
                    ),
                  IconAction(
                    Icons.ios_share_outlined,
                    '共有',
                    onPressed: onShare,
                  ),
                  IconAction(Icons.more_horiz, 'その他の操作', onPressed: onMore),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 1),
      ],
    ),
  );
}

class _Reaction extends StatelessWidget {
  const _Reaction({
    required this.icon,
    required this.label,
    required this.count,
    this.selected = false,
    this.onPressed,
  });
  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '$label $count件',
    onTap: onPressed,
    excludeSemantics: true,
    child: TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(Space.touch, Space.touch),
        foregroundColor: selected ? Palette.pinkContrast : Palette.secondary,
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      ),
      onPressed: onPressed,
      child: Wrap(
        spacing: Space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [Icon(icon, size: 19), Text('$count')],
      ),
    ),
  );
}

class ContentTile extends StatelessWidget {
  const ContentTile(
    this.title,
    this.icon, {
    super.key,
    required this.onPressed,
    this.detail,
  });
  final String title;
  final IconData icon;
  final VoidCallback onPressed;
  final String? detail;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.warm,
    borderRadius: BorderRadius.circular(Space.radius),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(Space.radius),
      child: Padding(
        padding: const EdgeInsets.all(Space.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Palette.yellow,
              foregroundColor: Palette.ink,
              child: Icon(icon, size: 20),
            ),
            const SizedBox(height: Space.sm),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (detail != null)
              Text(
                detail!,
                style: TypeStyles.caption.copyWith(color: Palette.secondary),
              ),
          ],
        ),
      ),
    ),
  );
}

class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.title,
    required this.detail,
    required this.cover,
    this.album = false,
    this.collection = false,
    this.downloaded = false,
    required this.onPressed,
  });

  final String title;
  final String detail;
  final Widget cover;
  final bool album;
  final bool collection;
  final bool downloaded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.surface,
    borderRadius: BorderRadius.circular(Space.radius),
    child: InkWell(
      borderRadius: BorderRadius.circular(Space.radius),
      onTap: onPressed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MediaFrame(ratio: album ? 3 / 4 : 16 / 9, child: cover),
          Padding(
            padding: const EdgeInsets.all(Space.gap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  detail,
                  style: TypeStyles.caption.copyWith(color: Palette.secondary),
                ),
                if (collection || downloaded) ...[
                  const SizedBox(height: Space.xs),
                  InfoTag(
                    downloaded ? '保存済み' : 'コレクション',
                    background: Palette.mutedBlue,
                    foreground: Palette.link,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class BannerDots extends StatelessWidget {
  const BannerDots({super.key, required this.index, required this.count});
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'おすすめ ${index + 1}／$count',
    excludeSemantics: true,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            height: 7,
            width: i == index ? 19 : 7,
            decoration: BoxDecoration(
              color: i == index ? Palette.warning : Palette.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    ),
  );
}
