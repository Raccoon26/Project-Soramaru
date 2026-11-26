CREATE TABLE stamp_sets (
  id TEXT PRIMARY KEY NOT NULL,
  label TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('draft','published','retired')),
  rights_state TEXT NOT NULL CHECK(rights_state IN ('synthetic','approved','pending','revoked')),
  version INTEGER NOT NULL CHECK(version>0)
) STRICT;
-- statement
CREATE TABLE stamp_items (
  id TEXT PRIMARY KEY NOT NULL,
  set_id TEXT NOT NULL REFERENCES stamp_sets(id),
  label TEXT NOT NULL,
  description TEXT NOT NULL,
  icon TEXT NOT NULL CHECK(icon IN ('sun','heart','tea','party','spark','moon','flower','wave')),
  position INTEGER NOT NULL CHECK(position>=0),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  version INTEGER NOT NULL CHECK(version>0),
  UNIQUE(set_id,position)
) STRICT;
-- statement
ALTER TABLE comments ADD COLUMN stamp_id TEXT REFERENCES stamp_items(id);
-- statement
ALTER TABLE media_reservations ADD COLUMN comment_scope INTEGER NOT NULL DEFAULT 0 CHECK(comment_scope IN (0,1));
-- statement
CREATE TABLE comment_media (
  comment_id TEXT PRIMARY KEY NOT NULL REFERENCES comments(id),
  media_id TEXT NOT NULL REFERENCES media_objects(id)
) STRICT;
-- statement
CREATE INDEX comment_media_object ON comment_media(media_id,comment_id);
-- statement
CREATE TRIGGER comment_photo_attach BEFORE INSERT ON comment_media
WHEN NOT EXISTS (
  SELECT 1 FROM comments c JOIN media_reservations r ON r.owner_id=c.author_id
  JOIN media_objects m ON m.id=r.id WHERE c.id=NEW.comment_id AND c.state='approved' AND r.id=NEW.media_id
  AND r.purpose='post' AND r.comment_scope=1 AND r.state IN ('approved','attached') AND m.width IS NOT NULL
  AND EXISTS(SELECT 1 FROM media_objects t JOIN media_reservations tr ON tr.id=t.id
    WHERE t.variant_of=r.id AND t.owner_id=r.owner_id AND t.width IS NOT NULL
    AND tr.purpose='thumbnail' AND tr.comment_scope=1 AND tr.state IN ('approved','attached'))
)
BEGIN SELECT RAISE(ABORT,'invalid_comment_attachment'); END;
-- statement
CREATE TRIGGER comment_photo_immutable BEFORE UPDATE ON comment_media
BEGIN SELECT RAISE(ABORT,'comment_attachment_immutable'); END;
-- statement
CREATE TRIGGER comment_photo_not_post BEFORE INSERT ON post_media
WHEN EXISTS(SELECT 1 FROM media_reservations WHERE id=NEW.media_id AND comment_scope=1)
BEGIN SELECT RAISE(ABORT,'invalid_post_photo'); END;
-- statement
CREATE INDEX comments_recent_author ON comments(author_id,created_at DESC,id DESC) WHERE state='approved';
-- statement
CREATE INDEX reactions_post ON reactions(post_id,member_id) WHERE post_id IS NOT NULL;
-- statement
CREATE INDEX reactions_comment ON reactions(comment_id,member_id) WHERE comment_id IS NOT NULL;
-- statement
CREATE INDEX reactions_recent_member ON reactions(member_id,created_at DESC);
-- statement
ALTER TABLE community_reports RENAME TO community_reports_previous;
-- statement
CREATE TABLE community_reports(
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
  reporter_id TEXT NOT NULL REFERENCES members(id),
  target_kind TEXT NOT NULL CHECK(target_kind IN ('post','member','comment')),
  target_id TEXT NOT NULL CHECK(length(target_id)=36),
  target_member_id TEXT NOT NULL REFERENCES members(id),
  target_version INTEGER NOT NULL CHECK(target_version>0),
  category TEXT NOT NULL CHECK(category IN ('spam','disruption','harassment','inappropriate','privacy','impersonation','copyright','other')),
  detail TEXT NOT NULL CHECK(length(detail)<=500),
  created_at INTEGER NOT NULL CHECK(created_at>=0),
  CHECK(reporter_id<>target_member_id),
  UNIQUE(reporter_id,target_kind,target_id)
) STRICT;
-- statement
INSERT INTO community_reports SELECT * FROM community_reports_previous ORDER BY rowid;
-- statement
DROP TABLE community_reports_previous;
-- statement
INSERT INTO stamp_sets VALUES ('greetings','開発用あいさつ','published','synthetic',1);
-- statement
INSERT INTO stamp_items VALUES
('hello','greetings','おはよう','朝日と「おはよう」', 'sun',0,1,1),
('thanks','greetings','ありがとう','ハートと「ありがとう」', 'heart',1,1,1),
('tea','greetings','おつかれさま','お茶と「おつかれさま」', 'tea',2,1,1),
('cheers','greetings','おめでとう','紙吹雪と「おめでとう」', 'party',3,1,1),
('great','greetings','いいね！','光と「いいね！」', 'spark',4,1,1),
('night','greetings','おやすみ','月と「おやすみ」', 'moon',5,1,1),
('happy','greetings','うれしい','花と「うれしい」', 'flower',6,1,1),
('later','greetings','またね','波と「またね」', 'wave',7,1,1);
