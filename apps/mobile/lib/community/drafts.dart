import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

final draftRepositoryProvider = Provider<DraftRepository?>((ref) => null);

String draftId() {
  final rng = Random.secure();
  return base64UrlEncode(List.generate(24, (_) => rng.nextInt(256)));
}

class Draft {
  const Draft({
    required this.id,
    required this.started,
    required this.updated,
    this.body = '',
    this.tags = const [],
    this.quoteId,
    this.postId,
    this.version,
    this.requestKey,
    this.attachments = const [],
  });
  factory Draft.fresh({String? quoteId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Draft(id: draftId(), started: now, updated: now, quoteId: quoteId);
  }

  final String id, body;
  final int started, updated;
  final List<String> tags, attachments;
  final String? quoteId, postId, requestKey;
  final int? version;

  Map<String, Object?> toJson() => {
    'id': id,
    'started': started,
    'updated': updated,
    'body': body,
    'tags': tags,
    'quote': quoteId,
    'post': postId,
    'version': version,
    'requestKey': requestKey,
    'attachments': attachments,
  };

  factory Draft.fromJson(Map<String, Object?> map) => Draft(
    id: map['id'] as String,
    started: map['started'] as int,
    updated: map['updated'] as int,
    body: map['body'] as String,
    tags: (map['tags'] as List).cast<String>(),
    quoteId: map['quote'] as String?,
    postId: map['post'] as String?,
    version: map['version'] as int?,
    requestKey: map['requestKey'] as String?,
    attachments: (map['attachments'] as List? ?? []).cast<String>(),
  );
}

abstract interface class DraftKeys {
  Future<String?> read(String owner);
  Future<void> write(String owner, String key);
  Future<void> remove(String owner);
}

class OsDraftKeys implements DraftKeys {
  const OsDraftKeys();
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  String _name(String owner) => 'soramaru.drafts.1.$owner';
  @override
  Future<String?> read(String owner) => _storage.read(key: _name(owner));
  @override
  Future<void> write(String owner, String key) =>
      _storage.write(key: _name(owner), value: key);
  @override
  Future<void> remove(String owner) => _storage.delete(key: _name(owner));
}

class DraftDatabase extends GeneratedDatabase {
  DraftDatabase(super.executor);
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async => customStatement(
      'CREATE TABLE drafts(owner TEXT NOT NULL,id TEXT NOT NULL,updated INTEGER NOT NULL,blob TEXT NOT NULL,PRIMARY KEY(owner,id))',
    ),
    onUpgrade: (_, from, to) async {
      if (from == 1) {
        await customStatement(
          'ALTER TABLE drafts ADD COLUMN updated INTEGER NOT NULL DEFAULT 0',
        );
      } else {
        throw StateError('Unknown drafts schema');
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA secure_delete=ON');
    },
  );
}

class DraftRepository {
  DraftRepository(this.database, this.keys);
  factory DraftRepository.local() => DraftRepository(
    DraftDatabase(
      LazyDatabase(() async {
        final support = await getApplicationSupportDirectory();
        final dir = Directory('${support.path}/soramaru-drafts');
        await dir.create(recursive: true);
        if (Platform.isIOS) {
          await const MethodChannel('dev.soramaru/drafts')
              .invokeMethod<void>('excludeFromBackup');
        }
        return NativeDatabase.createInBackground(
          File('${dir.path}/community-drafts.sqlite'),
        );
      }),
    ),
    const OsDraftKeys(),
  );

  final DraftDatabase database;
  final DraftKeys keys;
  final _cipher = AesGcm.with256bits();
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() task) {
    final next = _queue.then((_) => task());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> save(String owner, Draft draft) => _serial(() async {
    var raw = await keys.read(owner);
    if (raw == null) {
      raw = base64Encode(await (await _cipher.newSecretKey()).extractBytes());
      await keys.write(owner, raw);
    }
    final sealed = await _cipher.encrypt(
      utf8.encode(jsonEncode(draft.toJson())),
      secretKey: SecretKey(base64Decode(raw)),
      aad: utf8.encode('$owner:${draft.id}'),
    );
    await database.customStatement(
      'INSERT INTO drafts(owner,id,updated,blob) VALUES (?,?,?,?) ON CONFLICT(owner,id) DO UPDATE SET updated=excluded.updated,blob=excluded.blob',
      [owner, draft.id, draft.updated, base64Encode(sealed.concatenation())],
    );
  });

  Future<List<Draft>> list(String owner) => _serial(() async {
    final raw = await keys.read(owner);
    if (raw == null) return [];
    final key = SecretKey(base64Decode(raw));
    final rows = await database
        .customSelect(
          'SELECT id,blob FROM drafts WHERE owner=? ORDER BY updated DESC,id DESC',
          variables: [Variable(owner)],
        )
        .get();
    final drafts = <Draft>[];
    for (final row in rows) {
      try {
        final id = row.read<String>('id');
        final box = SecretBox.fromConcatenation(
          base64Decode(row.read<String>('blob')),
          nonceLength: 12,
          macLength: 16,
        );
        final plain = await _cipher.decrypt(
          box,
          secretKey: key,
          aad: utf8.encode('$owner:$id'),
        );
        drafts.add(
          Draft.fromJson(
            jsonDecode(utf8.decode(plain)) as Map<String, Object?>,
          ),
        );
      } on SecretBoxAuthenticationError {
        // An unreadable row never crosses into a different account's list.
      }
    }
    return drafts;
  });

  Future<void> remove(String owner, String id) => _serial(
    () => database.customStatement(
      'DELETE FROM drafts WHERE owner=? AND id=?',
      [owner, id],
    ),
  );

  Future<void> purge(String owner) => _serial(() async {
    await keys.remove(owner);
    await database.customStatement('DELETE FROM drafts WHERE owner=?', [owner]);
  });

  Future<void> close() => _serial(database.close);
}
