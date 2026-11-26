import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../membership/gateway.dart';
import '../ui/content.dart';
import '../ui/design.dart';
import 'community.dart';

class ReactionButton extends StatefulWidget {
  const ReactionButton(this.api, this.kind, this.id, this.value, {super.key});
  final Community api;
  final String kind, id;
  final Json value;

  @override
  State<ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<ReactionButton> {
  late bool confirmed = widget.value['liked'] == true, wanted = confirmed;
  late int count = widget.value['likes'] as int? ?? 0;
  bool sending = false;
  Timer? debounce;

  @override
  void didUpdateWidget(ReactionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!sending && debounce == null && oldWidget.value != widget.value) {
      confirmed = wanted = widget.value['liked'] == true;
      count = widget.value['likes'] as int? ?? 0;
    }
  }

  void toggle() {
    setState(() => wanted = !wanted);
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 220), () {
      debounce = null;
      unawaited(_send());
    });
  }

  Future<void> _send() async {
    if (sending || wanted == confirmed) return;
    final owner = widget.api.owner;
    sending = true;
    try {
      while (mounted &&
          owner != null &&
          widget.api.owner == owner &&
          wanted != confirmed) {
        final target = wanted;
        final data = await widget.api.account.community(
          '/v1/reactions/${widget.kind}/${widget.id}',
          method: target ? 'PUT' : 'DELETE',
        );
        if (!mounted || widget.api.owner != owner) return;
        if (data['liked'] is! bool || data['likes'] is! int) {
          throw const MembershipFailure('unavailable');
        }
        setState(() {
          if (wanted == target) wanted = data['liked'] as bool;
          confirmed = data['liked'] as bool;
          count = data['likes'] as int;
        });
      }
    } on MembershipFailure catch (error) {
      if (!mounted || widget.api.owner != owner) return;
      setState(() => wanted = confirmed);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      sending = false;
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ReactionControl(
    icon: wanted ? Icons.favorite : Icons.favorite_border,
    label: 'いいね',
    selected: wanted,
    selectedColor: Palette.warning,
    count: (count + (wanted ? 1 : 0) - (confirmed ? 1 : 0)).clamp(0, 10000000),
    onPressed: toggle,
  );
}
