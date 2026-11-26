import '../ui/controls.dart';

enum Access { public, member, artist }

enum Screen {
  feed('F01', 'feed'),
  post(
    'F02',
    'posts/:id',
    parent: feed,
    access: Access.member,
    linkKind: 'post',
  ),
  comments(
    'F05',
    'comments',
    parent: post,
    access: Access.member,
    linkKind: 'comment',
  ),
  compose(
    'F03',
    'compose',
    parent: feed,
    access: Access.member,
    fullScreen: true,
  ),
  pickPhoto(
    'F04',
    'photos',
    parent: compose,
    access: Access.member,
    fullScreen: true,
  ),
  pickTag(
    'F07A',
    'tags',
    parent: compose,
    access: Access.member,
    fullScreen: true,
  ),
  search('F06', 'search', parent: feed),
  tags('F07', 'tags', parent: feed),
  tagged('F07L', ':id', parent: tags),
  content('C01', 'content'),
  today('C02', 'today', parent: content, access: Access.member),
  voice('C03', 'voice', parent: content, access: Access.member),
  voiceDetail(
    'C04',
    'tracks/:id',
    parent: voice,
    access: Access.member,
    linkKind: 'voice',
  ),
  player(
    'C05',
    'play',
    parent: voiceDetail,
    access: Access.member,
    fullScreen: true,
  ),
  playlist('C06', 'playlist', parent: voice, access: Access.member),
  downloads('C07', 'downloads', parent: voice, access: Access.member),
  gallery('C08', 'gallery', parent: content, access: Access.member),
  album(
    'C09',
    ':id',
    parent: gallery,
    access: Access.member,
    linkKind: 'album',
  ),
  photo(
    'C09V',
    'photo',
    parent: album,
    access: Access.member,
    fullScreen: true,
  ),
  recent('C10', 'recent', parent: content, access: Access.member),
  notices('C11', 'notices', parent: content, access: Access.member),
  notice(
    'C11D',
    ':id',
    parent: notices,
    access: Access.member,
    linkKind: 'notice',
  ),
  goods('C12', 'goods', parent: content),
  notifications('N01', 'notifications', access: Access.member),
  personal(
    'N02',
    'personal/:id',
    parent: notifications,
    access: Access.member,
    linkKind: 'personal',
  ),
  profile('M01', 'profile', access: Access.member),
  editProfile('M02', 'edit', parent: profile, access: Access.member),
  membership(
    'M03',
    'membership',
    parent: profile,
    access: Access.member,
    fullScreen: true,
  ),
  badges('M04', 'badges', parent: profile, access: Access.member),
  badge(
    'M04D',
    ':id',
    parent: badges,
    access: Access.member,
    linkKind: 'badge',
  ),
  cards('M05', 'cards', parent: profile, access: Access.member),
  card('M05D', ':id', parent: cards, access: Access.member, linkKind: 'card'),
  activity('M06', 'activity', parent: profile, access: Access.member),
  favorites('M07', 'favorites', parent: profile, access: Access.member),
  collections('M08', 'collections', parent: profile, access: Access.member),
  folder('M08D', ':id', parent: collections, access: Access.member),
  devices('M09', 'devices', parent: profile, access: Access.member),
  device('M09D', ':id', parent: devices, access: Access.member),
  blocks('M10', 'blocks', parent: profile, access: Access.member),
  user(
    'M11',
    'users/:id',
    parent: profile,
    access: Access.member,
    linkKind: 'profile',
  ),
  more('S01', 'more'),
  notificationSettings(
    'S02',
    'notifications',
    parent: more,
    access: Access.member,
  ),
  settings('S03', 'settings', parent: more),
  faq('S04', 'faq', parent: more),
  support('S05', 'support', parent: more),
  terms('S06', 'terms', parent: more),
  privacy('S07', 'privacy', parent: more),
  deleteAccount('S08', 'delete', parent: more, access: Access.member),
  version('S09', 'version', parent: more),
  licenses('S10', 'licenses', parent: more),
  catalog('B00', 'catalog', parent: more, fullScreen: true),
  login('A01', 'login', fullScreen: true),
  artistPost('P01', 'studio/post', access: Access.artist, fullScreen: true),
  artistSchedule(
    'P02',
    'studio/schedule',
    access: Access.artist,
    fullScreen: true,
  ),
  artistRewards(
    'P03',
    'studio/rewards',
    access: Access.artist,
    fullScreen: true,
  ),
  restricted('B01', 'restricted', fullScreen: true),
  unavailable('B02', 'unavailable', fullScreen: true),
  invalidLink('B03', 'invalid-link', fullScreen: true);

  const Screen(
    this.id,
    this.segment, {
    this.parent,
    this.access = Access.public,
    this.linkKind,
    this.fullScreen = false,
  });

  final String id;
  final String segment;
  final Screen? parent;
  final Access access;
  final String? linkKind;
  final bool fullScreen;

  static const tabs = [feed, content, notifications, profile, more];
  static final byName = {for (final screen in values) screen.name: screen};

  Screen get root => parent?.root ?? this;
  CommunityTab? get tab {
    final index = tabs.indexOf(root);
    return index < 0 ? null : CommunityTab.values[index];
  }

  bool get hasTabBar => tab != null && !fullScreen;
  Screen get recovery => tab == null ? feed : root;
  String get pattern => '${parent?.pattern ?? ''}/$segment';
  bool get hasResource => pattern.contains(':id');

  String location([String? resource]) {
    if (!hasResource) return pattern;
    if (resource == null || !resourceId.hasMatch(resource)) {
      throw ArgumentError('A valid resource ID is required for $id');
    }
    return pattern.replaceFirst(':id', resource);
  }
}

final resourceId = RegExp(
  r'^(?:[a-z][a-z0-9-]{0,31}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$',
);

class Destination {
  const Destination(this.screen, [this.id, this.comment]);
  final Screen screen;
  final String? id;
  final String? comment;
  String get location =>
      '${screen.location(id)}${comment == null ? '' : '?comment=$comment'}';
}
