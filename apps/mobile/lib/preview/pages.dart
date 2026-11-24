import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/content.dart';
import '../ui/controls.dart';
import '../ui/design.dart';
import '../ui/feedback.dart';
import 'home.dart';

class PreviewPage extends StatelessWidget {
  const PreviewPage(
    this.title, {
    super.key,
    required this.child,
    this.onBack,
    this.action,
    this.close = false,
  });
  final String title;
  final Widget child;
  final VoidCallback? onBack;
  final Widget? action;
  final bool close;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          PageHeader(
            title,
            leading: IconAction(
              close ? Icons.close : Icons.arrow_back,
              close ? '閉じる' : '戻る',
              onPressed:
                  onBack ??
                  () {
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go('/');
                    }
                  },
            ),
            action: action,
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Space.maxContent),
                child: child,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class ComposePreview extends StatefulWidget {
  const ComposePreview({super.key});
  @override
  State<ComposePreview> createState() => _ComposePreviewState();
}

class _ComposePreviewState extends State<ComposePreview> {
  final _body = TextEditingController();
  final _tag = TextEditingController();
  final _tags = <String>['きょうの空'];
  int _attachments = 0;
  int _count = 0;
  bool _confirming = false;
  bool get _dirty =>
      _count > 0 ||
      _attachments > 0 ||
      _tags.length != 1 ||
      _tags.firstOrNull != 'きょうの空';

  @override
  void dispose() {
    _body.dispose();
    _tag.dispose();
    super.dispose();
  }

  void _exit() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _cancel() async {
    if (_confirming) return;
    if (!_dirty) {
      _exit();
      return;
    }
    _confirming = true;
    final confirmed = await confirmAction(
      context,
      title: '編集をやめますか？',
      message: '入力した内容は保存されません。',
      action: '編集をやめる',
      destructive: true,
    );
    _confirming = false;
    if (mounted && confirmed) _exit();
  }

  void _previewSubmit() {
    FocusScope.of(context).unfocus();
    showNotice(context, 'プレビューの投稿内容を確認しました。');
  }

  void _addTag() {
    final tag = _tag.text.trim().replaceFirst(RegExp(r'^#+'), '');
    if (tag.isEmpty || _tags.contains(tag) || _tags.length >= 5) return;
    setState(() => _tags.add(tag));
    _tag.clear();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancel();
    },
    child: PreviewPage(
      '記事を作成',
      close: true,
      onBack: _cancel,
      action: ActionButton(
        '確認',
        kind: ButtonKind.text,
        onPressed: _count > 0 ? _previewSubmit : null,
      ),
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(Space.edge),
        children: [
          InputField(
            '本文',
            controller: _body,
            multiline: true,
            maxLength: 500,
            hint: 'きょうの出来事を書いてみましょう。',
            onChanged: (value) =>
                setState(() => _count = value.characters.length),
          ),
          const SizedBox(height: Space.gap),
          const SectionTitle('ハッシュタグ'),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.xs,
            children: [
              for (final tag in _tags)
                TagChip(tag, onRemove: () => setState(() => _tags.remove(tag))),
            ],
          ),
          const SizedBox(height: Space.sm),
          InputField('タグを入力', controller: _tag, maxLength: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: ActionButton(
              'タグを追加',
              kind: ButtonKind.text,
              onPressed: _addTag,
            ),
          ),
          const SizedBox(height: Space.gap),
          const SectionTitle('添付'),
          if (_attachments > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.gap),
              child: Wrap(
                spacing: Space.sm,
                children: [
                  for (var index = 0; index < _attachments; index++)
                    SizedBox(
                      width: 80,
                      child: CoverArt(CoverScene.values[index], ratio: 1),
                    ),
                  IconAction(
                    Icons.remove_circle_outline,
                    '画像を外す',
                    onPressed: () => setState(() => _attachments--),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: AttachmentButton(
              count: _attachments,
              limit: 3,
              onPressed: () => showActions(context, '画像を追加', [
                const Padding(
                  padding: EdgeInsets.all(Space.edge),
                  child: Text('プレビューでは写真へのアクセスを求めず、イラストを追加します。'),
                ),
                Builder(
                  builder: (sheetContext) => SettingsRow(
                    'サンプル画像を追加',
                    icon: Icons.image_outlined,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (mounted && _attachments < 3) {
                        setState(() => _attachments++);
                      }
                    },
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: Space.xl),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              ActionButton(
                '下書きの確認',
                kind: ButtonKind.outline,
                onPressed: _dirty
                    ? () => showNotice(context, '入力内容を確認しました。')
                    : null,
              ),
              ActionButton(
                '投稿する',
                onPressed: _count > 0 ? _previewSubmit : null,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class MediaListPreview extends StatefulWidget {
  const MediaListPreview({super.key, this.album = false});
  final bool album;

  @override
  State<MediaListPreview> createState() => _MediaListPreviewState();
}

class _MediaListPreviewState extends State<MediaListPreview> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    return PreviewPage(
      album ? 'GALLERY' : 'VOICE',
      action: IconAction(
        Icons.search,
        '検索',
        onPressed: () => context.push('/search'),
      ),
      child: Column(
        children: [
          SectionTabs(
            album ? const ['すべて', 'コレクション'] : const ['すべて', '保存済み'],
            selected: _tab,
            onSelect: (value) => setState(() => _tab = value),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Space.edge),
              children: [
                AdaptiveTiles(
                  hub: false,
                  children: [
                    MediaCard(
                      title: album ? '夕暮れの色' : '朝のさんぽ便り',
                      detail: album ? 'イラスト · 3枚' : '音声サンプル · 3:48',
                      cover: Landscape(
                        album ? CoverScene.evening : CoverScene.morning,
                      ),
                      album: album,
                      collection: album,
                      downloaded: !album,
                      onPressed: () => album
                          ? _album(context, '夕暮れの色', CoverScene.evening)
                          : context.push('/player'),
                    ),
                    if (_tab == 0)
                      MediaCard(
                        title: album ? '海辺の風景' : '波の聞こえる場所',
                        detail: album ? 'イラスト · 2枚' : '音声サンプル · 3:48',
                        cover: const Landscape(CoverScene.coast),
                        album: album,
                        onPressed: () => album
                            ? _album(context, '海辺の風景', CoverScene.coast)
                            : context.push('/player?track=1'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _album(BuildContext context, String title, CoverScene scene) {
    showActions(context, title, [
      Padding(
        padding: const EdgeInsets.all(Space.edge),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Semantics(
            image: true,
            label: 'アルバムの風景イラスト',
            child: CoverArt(scene, ratio: 3 / 4),
          ),
        ),
      ),
    ]);
  }
}

class PlayerPreview extends StatefulWidget {
  const PlayerPreview({super.key, this.initialTrack = 0});
  final int initialTrack;

  @override
  State<PlayerPreview> createState() => _PlayerPreviewState();
}

class _PlayerPreviewState extends State<PlayerPreview> {
  late int _track = widget.initialTrack;
  bool _playing = false;
  bool _repeat = false;
  bool _shuffle = false;
  double _position = 65;
  static const _length = 228.0;
  static const _tracks = [
    ('朝のさんぽ便り', CoverScene.morning),
    ('波の聞こえる場所', CoverScene.coast),
  ];

  void _switchTrack() => setState(() {
    _track = (_track + 1) % _tracks.length;
    _position = 0;
  });
  String _time(double seconds) =>
      '${seconds ~/ 60}:${(seconds.toInt() % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final (title, art) = _tracks[_track];
    return PreviewPage(
      '音声プレーヤー',
      close: true,
      child: ListView(
        padding: const EdgeInsets.all(Space.edge),
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: Palette.night,
              borderRadius: BorderRadius.circular(Space.radius),
            ),
            child: Padding(
              padding: const EdgeInsets.all(Space.edge),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CoverArt(art),
                  const SizedBox(height: Space.edge),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TypeStyles.heading.copyWith(
                          color: Palette.surface,
                        ),
                      ),
                      const InfoTag('音声プレビュー'),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Slider(
                    value: _position,
                    max: _length,
                    activeColor: Palette.yellow,
                    inactiveColor: Palette.border,
                    semanticFormatterCallback: (value) =>
                        '${value ~/ 60}分${value.toInt() % 60}秒',
                    onChanged: (position) =>
                        setState(() => _position = position),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _time(_position),
                        style: const TextStyle(color: Palette.surface),
                      ),
                      Text(
                        _time(_length),
                        style: const TextStyle(color: Palette.surface),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.gap),
                  IconButtonTheme(
                    data: IconButtonThemeData(
                      style: IconButton.styleFrom(
                        foregroundColor: Palette.surface,
                      ),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconAction(
                          _shuffle ? Icons.shuffle_on : Icons.shuffle,
                          _shuffle ? 'シャッフルを解除' : 'シャッフル',
                          onPressed: () => setState(() => _shuffle = !_shuffle),
                        ),
                        IconAction(
                          Icons.skip_previous,
                          '前のトラック',
                          onPressed: _switchTrack,
                        ),
                        ActionButton(
                          _playing ? '一時停止' : '再生',
                          icon: _playing ? Icons.pause : Icons.play_arrow,
                          onPressed: () => setState(() => _playing = !_playing),
                        ),
                        IconAction(
                          Icons.skip_next,
                          '次のトラック',
                          onPressed: _switchTrack,
                        ),
                        IconAction(
                          _repeat ? Icons.repeat_on : Icons.repeat,
                          _repeat ? 'リピートを解除' : 'リピート',
                          onPressed: () => setState(() => _repeat = !_repeat),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SearchPreview extends StatefulWidget {
  const SearchPreview({super.key});
  @override
  State<SearchPreview> createState() => _SearchPreviewState();
}

class _SearchPreviewState extends State<SearchPreview> {
  String _query = '';

  @override
  Widget build(BuildContext context) => PreviewPage(
    '検索',
    child: ListView(
      padding: const EdgeInsets.all(Space.edge),
      children: [
        InputField(
          'キーワード',
          search: true,
          onChanged: (query) => setState(() => _query = query.trim()),
        ),
        const SizedBox(height: Space.edge),
        if (_query.isEmpty)
          const Text('投稿やコンテンツを検索')
        else if ('朝のさんぽ便り'.contains(_query))
          SettingsRow(
            '朝のさんぽ便り',
            icon: Icons.headphones,
            onTap: () => context.push('/player'),
          )
        else
          const StateNotice(ViewState.noResults),
      ],
    ),
  );
}

class SettingsPreview extends StatefulWidget {
  const SettingsPreview({super.key});
  @override
  State<SettingsPreview> createState() => _SettingsPreviewState();
}

class _SettingsPreviewState extends State<SettingsPreview> {
  bool _notices = true;
  bool _wifi = false;
  String _order = '新しい順';

  @override
  Widget build(BuildContext context) => PreviewPage(
    '通知・表示設定',
    child: ListView(
      padding: const EdgeInsets.all(Space.edge),
      children: [
        SwitchListTile(
          title: const Text('コンテンツのお知らせ'),
          value: _notices,
          onChanged: (value) => setState(() => _notices = value),
        ),
        CheckboxListTile(
          title: const Text('Wi-Fi接続時のみダウンロード'),
          value: _wifi,
          onChanged: (value) => setState(() => _wifi = value ?? false),
        ),
        const SizedBox(height: Space.edge),
        DropdownButtonFormField<String>(
          initialValue: _order,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '表示順'),
          items: const [
            DropdownMenuItem(value: '新しい順', child: Text('新しい順')),
            DropdownMenuItem(value: '古い順', child: Text('古い順')),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _order = value);
          },
        ),
      ],
    ),
  );
}

class StateCatalog extends StatelessWidget {
  const StateCatalog({super.key});

  @override
  Widget build(BuildContext context) => PreviewPage(
    '画面状態と操作',
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: ListView.builder(
        padding: const EdgeInsets.all(Space.edge),
        itemCount: ViewState.values.length + 1,
        itemBuilder: (context, index) {
          if (index == ViewState.values.length) return const _ButtonCatalog();
          final status = ViewState.values[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: Space.gap),
            child: StateNotice(
              status,
              compact:
                  status == ViewState.refreshing || status == ViewState.network,
              onRetry: status == ViewState.network || status == ViewState.signIn
                  ? () => showNotice(context, 'プレビューの操作を確認しました。')
                  : null,
            ),
          );
        },
      ),
    ),
  );
}

class _ButtonCatalog extends StatelessWidget {
  const _ButtonCatalog();

  @override
  Widget build(BuildContext context) {
    void sample() => showNotice(context, 'プレビューの操作を確認しました。');
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        ActionButton('確認する', onPressed: sample),
        ActionButton('あとで見る', kind: ButtonKind.secondary, onPressed: sample),
        ActionButton(
          '閉じる',
          kind: ButtonKind.outline,
          onPressed: () => context.pop(),
        ),
        ActionButton('詳しく見る', kind: ButtonKind.text, onPressed: sample),
        const ActionButton('選択できません'),
        const ActionButton('保存する', loading: true),
        ActionButton(
          '削除する',
          kind: ButtonKind.danger,
          onPressed: () async {
            final deleted = await confirmAction(
              context,
              title: '削除しますか？',
              message: 'プレビューの項目です。',
              action: '削除する',
              destructive: true,
            );
            if (deleted && context.mounted) sample();
          },
        ),
      ],
    );
  }
}
