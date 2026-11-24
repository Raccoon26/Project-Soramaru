import 'destinations.dart';
import 'sample_data.dart';

class DeepLinks {
  const DeepLinks(this.resources);
  final NavigationResources resources;
  static const maxLength = 128;
  static final _shape = RegExp(
    r'^soramaru-dev://open/([a-z-]+)/([a-z][a-z0-9-]{0,31})$',
  );

  Destination? parse(String input) {
    if (input.length > maxLength || input.contains(RegExp(r'\s'))) return null;
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
