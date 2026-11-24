import 'destinations.dart';

const screenTitles = <Screen, String>{
  Screen.feed: 'ファン投稿',
  Screen.post: '投稿詳細',
  Screen.comments: 'コメント・スタンプ',
  Screen.compose: '記事を作成',
  Screen.pickPhoto: '写真を選択',
  Screen.pickTag: 'タグを追加',
  Screen.search: '検索',
  Screen.tags: '人気のタグ',
  Screen.tagged: 'タグの投稿',
  Screen.content: 'コンテンツ',
  Screen.today: '今日のヒトコト',
  Screen.voice: 'VOICE・RADIO',
  Screen.voiceDetail: '音声詳細',
  Screen.player: '音声プレーヤー',
  Screen.playlist: 'プレイリスト',
  Screen.downloads: 'ダウンロード',
  Screen.gallery: 'GALLERY',
  Screen.album: 'アルバム',
  Screen.photo: '写真ビューア',
  Screen.recent: '最近見たコンテンツ',
  Screen.notices: '公式のお知らせ',
  Screen.notice: 'お知らせ詳細',
  Screen.goods: 'チケット・グッズ',
  Screen.notifications: '通知',
  Screen.personal: 'あなたへのお知らせ',
  Screen.profile: 'マイページ',
  Screen.editProfile: 'プロフィール編集',
  Screen.membership: 'デジタル会員証',
  Screen.badges: 'バッジ',
  Screen.badge: 'バッジ詳細',
  Screen.cards: 'メッセージカード',
  Screen.card: 'メッセージカード詳細',
  Screen.activity: '最近の活動・投稿一覧',
  Screen.favorites: 'お気に入り',
  Screen.collections: 'コレクション',
  Screen.folder: 'フォルダ',
  Screen.devices: 'ログイン端末',
  Screen.device: '端末情報',
  Screen.blocks: 'ブロック一覧',
  Screen.user: 'ユーザープロフィール',
  Screen.more: 'その他',
  Screen.notificationSettings: '通知設定',
  Screen.settings: 'アプリ設定',
  Screen.faq: 'よくある質問',
  Screen.support: 'お問い合わせ',
  Screen.terms: '利用規約',
  Screen.privacy: 'プライバシーポリシー',
  Screen.deleteAccount: 'アカウント削除',
  Screen.version: 'バージョン情報',
  Screen.licenses: 'ライセンス',
  Screen.catalog: '画面状態と操作',
  Screen.login: 'ログイン・新規登録',
  Screen.artistPost: '公式投稿・収録',
  Screen.artistSchedule: '公開設定・ギャラリー管理',
  Screen.artistRewards: 'バッジ・カード管理',
  Screen.restricted: 'アクセスできません',
  Screen.unavailable: 'コンテンツを表示できません',
  Screen.invalidLink: 'リンクを開けません',
};

abstract final class Ja {
  static const demoSignIn = 'サンプル会員で続ける';
  static const demoSignOut = 'サンプル会員からログアウト';
  static const preview = '開発プレビュー';
  static const back = '戻る';
  static const close = '閉じる';
  static const search = 'キーワード';
  static const all = 'すべて';
  static const unread = '未読';
  static const read = '既読';
  static const empty = '表示できる項目がありません。';
  static const loading = 'ログイン状態を確認しています。';
  static const memberOnly = 'ログインしてからご利用ください。';
  static const roleOnly = 'この画面を開く権限がありません。';
  static const verifyEmail = 'メールアドレスを確認してください。';
  static const reviewTerms = '利用規約の確認が必要です。';
  static const sessionExpired = 'ログインの有効期限が切れました。';
  static const accountSuspended = 'このアカウントの利用は停止されています。';
  static const accountDeleting = 'アカウントの削除処理中です。';
  static const missing = '指定されたコンテンツが見つかりません。';
  static const removed = 'このコンテンツは削除されました。';
  static const privateContent = 'このコンテンツを閲覧する権限がありません。';
  static const badLink = 'このリンクは無効か、利用できません。';
  static const demoOnly = '開発中の表示サンプルです。';
  static const saveDemo = 'プレビューで保存';
  static const cancel = 'キャンセル';

  static String title(Screen screen) => screenTitles[screen]!;
  static String pieces(int count) => '${number(count)}件';
  static String number(int count) {
    final digits = count.abs().toString();
    final grouped = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    return count < 0 ? '−$grouped' : grouped;
  }

  // Use Japan Standard Time without consulting the device time zone.
  static DateTime jst(DateTime time) =>
      time.toUtc().add(const Duration(hours: 9));
  static String date(DateTime time) {
    final value = jst(time);
    return '${value.year}年${value.month}月${value.day}日';
  }

  static String time(DateTime value) {
    final time = jst(value);
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  static String relative(DateTime value, DateTime now) {
    final age = now.difference(value);
    if (age.isNegative) return '${date(value)} ${time(value)}';
    if (age.inMinutes < 1) return 'たった今';
    if (age.inHours < 1) return '${age.inMinutes}分前';
    if (age.inDays < 1) return '${age.inHours}時間前';
    if (age.inDays < 7) return '${age.inDays}日前';
    return date(value);
  }
}
