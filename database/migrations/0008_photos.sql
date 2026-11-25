ALTER TABLE media_reservations ADD COLUMN purpose TEXT CHECK(purpose IN ('post','thumbnail','avatar','gallery'));
-- statement
ALTER TABLE media_reservations ADD COLUMN expected_sha TEXT CHECK(length(expected_sha)=64 AND expected_sha NOT GLOB '*[^0-9a-f]*');
-- statement
ALTER TABLE media_reservations ADD COLUMN variant_id TEXT REFERENCES media_reservations(id);
-- statement
ALTER TABLE media_reservations ADD COLUMN quarantine_released INTEGER NOT NULL DEFAULT 0 CHECK(quarantine_released IN (0,1));
-- statement
ALTER TABLE media_objects ADD COLUMN width INTEGER CHECK(width BETWEEN 1 AND 2048);
-- statement
ALTER TABLE media_objects ADD COLUMN height INTEGER CHECK(height BETWEEN 1 AND 2048);
-- statement
CREATE INDEX media_thumbnail ON media_objects(variant_of, owner_id);
-- statement
CREATE UNIQUE INDEX media_one_live_thumbnail ON media_reservations(variant_id) WHERE purpose='thumbnail' AND state IN ('reserved','quarantined','approved','attached');
-- statement
CREATE INDEX media_photo_age ON media_reservations(state,updated_at,id) WHERE purpose IS NOT NULL;
-- statement
CREATE INDEX post_media_by_object ON post_media(media_id,post_id);
-- statement
CREATE INDEX member_photo_by_object ON member_profiles(avatar_media_id,member_id);
-- statement
CREATE TABLE photo_albums(
  content_id TEXT PRIMARY KEY NOT NULL REFERENCES content_items(id),
  identity_id TEXT NOT NULL REFERENCES official_identities(id),
  rights_state TEXT NOT NULL CHECK(rights_state IN ('pending','synthetic','approved'))
) STRICT;
-- statement
CREATE TABLE photo_album_items(
  album_id TEXT NOT NULL REFERENCES photo_albums(content_id),
  media_id TEXT NOT NULL REFERENCES media_objects(id),
  position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 99),
  PRIMARY KEY(album_id,position),
  UNIQUE(album_id,media_id)
) STRICT;
-- statement
CREATE INDEX photo_album_media ON photo_album_items(media_id,album_id);
-- statement
CREATE TRIGGER photo_album_attach BEFORE INSERT ON photo_album_items
WHEN NOT EXISTS(
  SELECT 1 FROM photo_albums a JOIN content_items c ON c.id=a.content_id
    JOIN official_identities o ON o.id=a.identity_id AND o.member_id=c.publisher_id
    JOIN media_reservations r ON r.id=NEW.media_id AND r.owner_id=c.publisher_id
  WHERE a.content_id=NEW.album_id AND c.kind='gallery' AND c.state NOT IN ('hidden','deleted')
    AND r.purpose='gallery' AND r.state IN ('approved','attached')
)
BEGIN SELECT RAISE(ABORT,'invalid_album_attachment'); END;
-- statement
CREATE TRIGGER photo_post_purpose BEFORE INSERT ON post_media
WHEN EXISTS(SELECT 1 FROM media_reservations WHERE id=NEW.media_id AND purpose IS NOT NULL AND purpose<>'post')
BEGIN SELECT RAISE(ABORT,'invalid_post_photo'); END;
-- statement
CREATE TRIGGER photo_reservation_settle AFTER UPDATE OF quarantine_released ON media_reservations
WHEN NEW.quarantine_released=1 AND OLD.quarantine_released=0 AND NEW.state IN ('approved','attached')
BEGIN UPDATE media_capacity SET held_bytes=held_bytes-NEW.reserved_bytes WHERE singleton=1; END;
-- statement
CREATE TRIGGER photo_reservation_release_offset BEFORE UPDATE OF state ON media_reservations
WHEN OLD.state='deleting' AND OLD.quarantine_released=1 AND NEW.state IN ('cancelled','deleted','expired')
BEGIN UPDATE media_capacity SET held_bytes=held_bytes+OLD.reserved_bytes WHERE singleton=1; END;
