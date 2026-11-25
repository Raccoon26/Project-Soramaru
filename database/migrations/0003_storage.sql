
CREATE TABLE media_capacity (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  held_bytes INTEGER NOT NULL CHECK(held_bytes >= 0)
) STRICT;
-- statement
INSERT INTO media_capacity VALUES (1, 0);
-- statement
CREATE TABLE media_owner_capacity (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES members(id),
  held_bytes INTEGER NOT NULL CHECK(held_bytes >= 0),
  pending INTEGER NOT NULL CHECK(pending >= 0)
) STRICT;
-- statement
CREATE TABLE media_reservations (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  owner_id TEXT NOT NULL REFERENCES members(id),
  request_key TEXT NOT NULL CHECK(length(request_key) BETWEEN 8 AND 80),
  reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 1 AND 26214400),
  mime TEXT NOT NULL CHECK(mime IN ('image/jpeg','image/png','image/webp','audio/mp4','application/octet-stream')),
  state TEXT NOT NULL CHECK(state IN ('reserved','quarantined','approved','attached','deleting','cancelled','expired','deleted')),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  expires_at INTEGER NOT NULL CHECK(expires_at > created_at),
  updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),
  UNIQUE(owner_id, request_key),
  UNIQUE(id, owner_id)
) STRICT;
-- statement
CREATE INDEX reservations_expiry ON media_reservations(state, expires_at, id);
-- statement
CREATE TRIGGER reservations_account_insert AFTER INSERT ON media_reservations
BEGIN
  UPDATE media_capacity SET held_bytes = held_bytes + 2 * NEW.reserved_bytes WHERE singleton = 1;
  INSERT INTO media_owner_capacity VALUES (NEW.owner_id, NEW.reserved_bytes, 1)
  ON CONFLICT(owner_id) DO UPDATE SET held_bytes=held_bytes+NEW.reserved_bytes, pending=pending+1;
END;
-- statement
CREATE TRIGGER reservations_initial BEFORE INSERT ON media_reservations
WHEN NEW.state <> 'reserved'
BEGIN SELECT RAISE(ABORT,'reservation_initial_state'); END;
-- statement
CREATE TRIGGER reservations_protect BEFORE UPDATE OF owner_id,reserved_bytes,mime,expires_at,request_key ON media_reservations
BEGIN SELECT RAISE(ABORT,'reservation_immutable'); END;
-- statement
CREATE TRIGGER reservations_no_delete BEFORE DELETE ON media_reservations
BEGIN SELECT RAISE(ABORT,'reservation_tombstone_required'); END;
-- statement
CREATE TRIGGER reservations_transition BEFORE UPDATE OF state ON media_reservations
WHEN NEW.state <> OLD.state AND NOT (
  (OLD.state = 'reserved' AND NEW.state IN ('quarantined','deleting')) OR
  (OLD.state = 'quarantined' AND NEW.state IN ('approved','deleting')) OR
  (OLD.state = 'approved' AND NEW.state IN ('attached','deleting')) OR
  (OLD.state = 'attached' AND NEW.state = 'deleting') OR
  (OLD.state = 'deleting' AND NEW.state IN ('cancelled','expired','deleted'))
)
BEGIN SELECT RAISE(ABORT,'reservation_transition'); END;
-- statement
CREATE TRIGGER reservations_release AFTER UPDATE OF state ON media_reservations
WHEN OLD.state = 'deleting' AND NEW.state IN ('cancelled','expired','deleted')
BEGIN
  UPDATE media_capacity SET held_bytes = held_bytes - 2 * NEW.reserved_bytes WHERE singleton = 1;
  UPDATE media_owner_capacity SET held_bytes=held_bytes-NEW.reserved_bytes WHERE owner_id=NEW.owner_id;
END;
-- statement
CREATE TRIGGER reservations_leave_pending AFTER UPDATE OF state ON media_reservations
WHEN OLD.state IN ('reserved','quarantined') AND NEW.state IN ('approved','deleting')
BEGIN UPDATE media_owner_capacity SET pending=pending-1 WHERE owner_id=NEW.owner_id; END;
-- statement
CREATE TABLE media_objects (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE CHECK(object_key = 'objects/' || id),
  actual_bytes INTEGER NOT NULL CHECK(actual_bytes > 0),
  mime TEXT NOT NULL,
  sha256 TEXT NOT NULL CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  variant_of TEXT,
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  FOREIGN KEY(id, owner_id) REFERENCES media_reservations(id,owner_id),
  UNIQUE(id,owner_id),
  FOREIGN KEY(variant_of,owner_id) REFERENCES media_objects(id,owner_id)
) STRICT;
-- statement
CREATE TRIGGER media_initial BEFORE INSERT ON media_objects
WHEN NOT EXISTS (SELECT 1 FROM media_reservations r WHERE r.id=NEW.id AND r.owner_id=NEW.owner_id
  AND r.state='reserved' AND r.reserved_bytes>=NEW.actual_bytes AND r.mime=NEW.mime)
BEGIN SELECT RAISE(ABORT,'invalid_object_reservation'); END;
-- statement
CREATE INDEX media_owner_digest ON media_objects(owner_id, sha256, actual_bytes);
-- statement
CREATE TABLE post_media (
  post_id TEXT NOT NULL REFERENCES posts(id),
  media_id TEXT NOT NULL REFERENCES media_objects(id),
  position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 9),
  PRIMARY KEY(post_id,position),
  UNIQUE(post_id,media_id)
) STRICT;
-- statement
CREATE TRIGGER post_media_attach BEFORE INSERT ON post_media
WHEN NOT EXISTS (
  SELECT 1 FROM posts AS p JOIN media_reservations AS r ON r.owner_id=p.author_id
  WHERE p.id=NEW.post_id AND p.state NOT IN ('deleted','hidden')
    AND r.id=NEW.media_id AND r.state IN ('approved','attached') AND r.mime LIKE 'image/%'
)
BEGIN SELECT RAISE(ABORT,'invalid_attachment'); END;
-- statement
CREATE TRIGGER post_media_immutable BEFORE UPDATE ON post_media
BEGIN SELECT RAISE(ABORT,'replace_attachment'); END;
-- statement
CREATE TABLE content_items (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  publisher_id TEXT NOT NULL REFERENCES members(id),
  kind TEXT NOT NULL CHECK(kind IN ('word','voice','radio','gallery','notice')),
  title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 120),
  state TEXT NOT NULL CHECK(state IN ('draft','approved','hidden','deleted')),
  visibility TEXT NOT NULL CHECK(visibility IN ('members','private')),
  publish_at INTEGER NOT NULL CHECK(publish_at >= 0),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1)
) STRICT;
-- statement
CREATE INDEX content_kind_due ON content_items(kind,state,visibility,publish_at DESC,id DESC);
-- statement
CREATE INDEX content_due ON content_items(state,publish_at,id);
