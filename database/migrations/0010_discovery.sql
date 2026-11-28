CREATE TABLE search_documents (
  rowid INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('post','member','tag','album')),
  target TEXT NOT NULL CHECK(length(target)=36),
  prefix TEXT NOT NULL,
  body TEXT NOT NULL,
  source_version INTEGER NOT NULL,
  UNIQUE(kind,target)
) STRICT;
-- statement
CREATE INDEX search_prefix ON search_documents(kind,prefix,rowid);
-- statement
CREATE VIRTUAL TABLE search_fts USING fts5(body, content='search_documents', content_rowid='rowid', tokenize='trigram');
-- statement
CREATE VIRTUAL TABLE album_fts USING fts5(body, content='search_documents', content_rowid='rowid', tokenize='trigram');
-- statement
CREATE TRIGGER search_document_insert AFTER INSERT ON search_documents WHEN NEW.kind='post'
BEGIN INSERT INTO search_fts(rowid,body) VALUES (NEW.rowid,NEW.body); END;
-- statement
CREATE TRIGGER search_document_update AFTER UPDATE OF body ON search_documents WHEN NEW.kind='post' AND OLD.body<>NEW.body
BEGIN
  INSERT INTO search_fts(search_fts,rowid,body) VALUES ('delete',OLD.rowid,OLD.body);
  INSERT INTO search_fts(rowid,body) VALUES (NEW.rowid,NEW.body);
END;
-- statement
CREATE TRIGGER search_document_delete AFTER DELETE ON search_documents WHEN OLD.kind='post'
BEGIN INSERT INTO search_fts(search_fts,rowid,body) VALUES ('delete',OLD.rowid,OLD.body); END;
-- statement
CREATE TRIGGER search_album_insert AFTER INSERT ON search_documents WHEN NEW.kind='album'
BEGIN INSERT INTO album_fts(rowid,body) VALUES (NEW.rowid,NEW.body); END;
-- statement
CREATE TRIGGER search_album_update AFTER UPDATE OF body ON search_documents WHEN NEW.kind='album' AND OLD.body<>NEW.body
BEGIN
  INSERT INTO album_fts(album_fts,rowid,body) VALUES ('delete',OLD.rowid,OLD.body);
  INSERT INTO album_fts(rowid,body) VALUES (NEW.rowid,NEW.body);
END;
-- statement
CREATE TRIGGER search_album_delete AFTER DELETE ON search_documents WHEN OLD.kind='album'
BEGIN INSERT INTO album_fts(album_fts,rowid,body) VALUES ('delete',OLD.rowid,OLD.body); END;
-- statement
CREATE TRIGGER search_album_unpublish AFTER UPDATE OF state,visibility ON content_items
WHEN OLD.kind='gallery' AND (NEW.state IN ('hidden','deleted') OR NEW.visibility<>'members')
BEGIN DELETE FROM search_documents WHERE kind='album' AND target=NEW.id; END;
-- statement
CREATE TRIGGER search_post_unpublish AFTER UPDATE OF state ON posts WHEN NEW.state IN ('hidden','deleted')
BEGIN DELETE FROM search_documents WHERE kind='post' AND target=NEW.id; END;
-- statement
ALTER TABLE posts ADD COLUMN quote_album_id TEXT REFERENCES content_items(id) ON DELETE SET NULL
  CHECK(quote_album_id IS NULL OR quote_post_id IS NULL);
-- statement
CREATE INDEX posts_by_album ON posts(quote_album_id,state,created_at DESC,id DESC) WHERE quote_album_id IS NOT NULL;
-- statement
CREATE TABLE favorite_posts (
  owner_id TEXT NOT NULL REFERENCES members(id),
  target_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,target_id)
) STRICT;
-- statement
CREATE INDEX favorite_posts_page ON favorite_posts(owner_id,created_at DESC,target_id DESC);
-- statement
CREATE TABLE favorite_members (
  owner_id TEXT NOT NULL REFERENCES members(id),
  target_id TEXT NOT NULL REFERENCES members(id),
  created_at INTEGER NOT NULL,
  CHECK(owner_id<>target_id),
  PRIMARY KEY(owner_id,target_id)
) STRICT;
-- statement
CREATE INDEX favorite_members_page ON favorite_members(owner_id,created_at DESC,target_id DESC);
-- statement
CREATE TABLE favorite_tags (
  owner_id TEXT NOT NULL REFERENCES members(id),
  target_id TEXT NOT NULL REFERENCES tags(id),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,target_id)
) STRICT;
-- statement
CREATE INDEX favorite_tags_page ON favorite_tags(owner_id,created_at DESC,target_id DESC);
-- statement
CREATE TABLE collection_folders (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
  owner_id TEXT NOT NULL REFERENCES members(id),
  title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 120),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version>=1),
  created_at INTEGER NOT NULL,
  UNIQUE(owner_id,id)
) STRICT;
-- statement
CREATE INDEX collection_folders_owner ON collection_folders(owner_id,id);
-- statement
CREATE TABLE collection_entries (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
  folder_id TEXT NOT NULL REFERENCES collection_folders(id) ON DELETE CASCADE,
  post_id TEXT REFERENCES posts(id),
  album_id TEXT REFERENCES content_items(id),
  photo_id TEXT REFERENCES media_objects(id),
  created_at INTEGER NOT NULL,
  CHECK((post_id IS NULL)<>(album_id IS NULL))
) STRICT;
-- statement
CREATE UNIQUE INDEX collection_entry_ref ON collection_entries(folder_id,coalesce(post_id,album_id),coalesce(photo_id,''));
-- statement
CREATE INDEX collection_entries_page ON collection_entries(folder_id,created_at DESC,id DESC);
-- statement
CREATE INDEX collection_entries_album ON collection_entries(album_id,folder_id) WHERE album_id IS NOT NULL;
-- statement
CREATE TABLE recent_albums (
  owner_id TEXT NOT NULL REFERENCES members(id),
  album_id TEXT NOT NULL REFERENCES content_items(id),
  seen_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,album_id)
) STRICT;
-- statement
CREATE INDEX recent_albums_page ON recent_albums(owner_id,seen_at DESC,album_id DESC);
-- statement
CREATE TABLE tag_discovery_snapshot (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  captured_at INTEGER NOT NULL,
  posts TEXT NOT NULL CHECK(json_valid(posts) AND json_array_length(posts)<=96)
) STRICT;
-- statement
CREATE TABLE discovery_backfill (
  kind TEXT PRIMARY KEY NOT NULL CHECK(kind IN ('post','member','tag','album')),
  last_id TEXT NOT NULL
) STRICT;
-- statement
CREATE INDEX blocks_manage ON blocks(blocker_id,created_at DESC,blocked_id DESC);
-- statement
CREATE INDEX post_photo_references ON post_media(media_id,post_id);
-- statement
CREATE TABLE post_photo_origins (
  media_id TEXT PRIMARY KEY NOT NULL REFERENCES media_objects(id),
  post_id TEXT NOT NULL REFERENCES posts(id)
) STRICT;
-- statement
CREATE TRIGGER post_photo_reuse BEFORE INSERT ON post_media
WHEN EXISTS (
  SELECT 1 FROM post_photo_origins origin WHERE origin.media_id=NEW.media_id AND origin.post_id<>NEW.post_id
    AND NOT EXISTS (SELECT 1 FROM post_media pm JOIN posts p ON p.id=pm.post_id
      WHERE pm.post_id=origin.post_id AND pm.media_id=NEW.media_id AND p.state='approved'
        AND p.publish_at<=(SELECT updated_at FROM posts WHERE id=NEW.post_id)))
BEGIN SELECT RAISE(ABORT,'invalid_photo_origin'); END;
-- statement
CREATE TRIGGER post_photo_origin AFTER INSERT ON post_media
BEGIN
  INSERT INTO post_photo_origins(media_id,post_id) VALUES (NEW.media_id,coalesce((
    SELECT pm.post_id FROM post_media pm JOIN posts p ON p.id=pm.post_id
    WHERE pm.media_id=NEW.media_id AND pm.post_id<>NEW.post_id ORDER BY p.created_at,p.id LIMIT 1
  ),NEW.post_id)) ON CONFLICT(media_id) DO NOTHING;
END;
-- statement
CREATE INDEX delivered_outbox_cleanup ON outbox(delivered_at,id) WHERE delivered_at IS NOT NULL;
