import 'destinations.dart';
import 'sample_data.dart';

class DeepLinks {
  const DeepLinks(this.resources, {this.community = false});
  final NavigationResources resources;
  final bool community;
  static const maxLength = 128;
  static final _shape = RegExp(
    r'^soramaru-dev://open/([a-z-]+)/([a-z][a-z0-9-]{0,31})$',
  );

  static final _forumShape = RegExp(
    r'^soramaru-dev://open/(post|profile|album|comment)/([0-9a-f-]{36})$',
  );

  Destination? parse(String input) {
    if (input.length > maxLength || input.contains(RegExp(r'\s'))) return null;
    final forum = community ? _forumShape.firstMatch(input) : null;
    if (forum != null && resourceId.hasMatch(forum[2]!)) {
      if (forum[1] == 'comment' && forum[2]!.length == 36) {
        return Destination(Screen.comments, forum[2], forum[2]);
      }
      return Destination(switch (forum[1]) {
        'post' => Screen.post,
        'album' => Screen.album,
        _ => Screen.user,
      }, forum[2]);
    }
    final match = _shape.firstMatch(input);
    if (match == null) return null;
    final kind = match[1]!;
    final id = match[2]!;
    for (final screen in Screen.values) {
      if (screen.linkKind != kind) continue;
      if (screen == Screen.comments) {
        return Destination(screen, resources.postForComment(id) ?? 'missing');
      }
      return Destination(screen, id);
    }
    return null;
  }
}

class PendingDestination {
  const PendingDestination(this.destination, this.generation, this.expires);
  final Destination destination;
  final int generation;
  final DateTime expires;

  bool valid(int currentGeneration, DateTime now) =>
      generation == currentGeneration && now.isBefore(expires);
}
