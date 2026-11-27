import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:unorm_dart/unorm_dart.dart' as unicode;

import '../membership/gateway.dart';
import '../ui/design.dart';
import 'community.dart';
import 'discovery.dart';

class TagPicker extends StatefulWidget {
  const TagPicker(this.api, this.initial, {super.key});
  final Community api;
  final List<String> initial;
  @override
  State<TagPicker> createState() => _TagPickerState();
}

String tagKey(String value) =>
    unicode.nfkc(value.trim().replaceFirst(RegExp(r'^[#＃]'), '')).toLowerCase();

class _TagPickerState extends State<TagPicker> {
  late final tags = [...widget.initial];
  final input = TextEditingController();
  Timer? debounce;
  String? query;
  String? message;
  bool favorites = false;

  @override
  void dispose() {
    debounce?.cancel();
    input.dispose();
    super.dispose();
  }

  void pick(String value) {
    final label = value.trim().replaceFirst(RegExp(r'^[#＃]'), '');
    final key = tagKey(label);
    if (!RegExp(r'^[\p{L}\p{M}\p{N}_-]{1,48}$', unicode: true).hasMatch(key) ||
        label.runes.length > 48) {
      setState(() => message = 'タグは文字・数字などを使って48文字以内で入力してください。');
    } else if (tags.any((tag) => tagKey(tag) == key)) {
      setState(() => message = '同じタグが追加されています。');
    } else if (tags.length >= 10) {
      setState(() => message = 'タグは10個まで追加できます。');
    } else {
      setState(() {
        tags.add(label);
        query = null;
        message = null;
        input.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('タグを追加'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, tags),
          child: const Text('完了'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.edge),
            child: Column(
              children: [
                TextField(
                  controller: input,
                  maxLength: 48,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) {
                    debounce?.cancel();
                    if (value.trim().length < 2) {
                      setState(() => query = null);
                      return;
                    }
                    debounce = Timer(const Duration(milliseconds: 400), () {
                      if (mounted) {
                        setState(
                          () => query = value.trim().replaceFirst(
                            RegExp(r'^[#＃]'),
                            '',
                          ),
                        );
                      }
                    });
                  },
                  onSubmitted: (value) => setState(() => query = value.trim()),
                  decoration: InputDecoration(
                    labelText: 'タグを検索',
                    suffixIcon: IconButton(
                      tooltip: '新しいタグを追加',
                      icon: const Icon(Icons.add),
                      onPressed: () => pick(input.text),
                    ),
                  ),
                ),
                Text('選択（${tags.length}/10）'),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: Space.sm,
                      children: [
                        for (final tag in tags)
                          InputChip(
                            label: Text('#$tag'),
                            onDeleted: () => setState(() => tags.remove(tag)),
                          ),
                      ],
                    ),
                  ),
                ),
                if (message case final error?)
                  Semantics(liveRegion: true, child: Text(error)),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        favorites = false;
                        query = null;
                      }),
                      child: const Text('人気のタグ'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        favorites = true;
                        query = null;
                      }),
                      child: const Text('お気に入り'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: DiscoveryPage(
              widget.api,
              query?.isNotEmpty == true
                  ? '/v1/search'
                  : favorites
                  ? '/v1/favorites'
                  : '/v1/tags/popular',
              key: ValueKey((query, favorites)),
              params: query?.isNotEmpty == true
                  ? {'q': query!, 'kind': 'tag'}
                  : favorites
                  ? const {'kind': 'tag'}
                  : const {},
              row: (context, Json row) => ListTile(
                title: Text('#${row['label']}'),
                trailing: const Icon(Icons.add),
                onTap: () => pick(row['label'] as String),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
