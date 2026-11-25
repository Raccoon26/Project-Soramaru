ALTER TABLE posts RENAME COLUMN body TO legacy_body;
-- statement
ALTER TABLE posts ADD COLUMN body TEXT NOT NULL DEFAULT '' CHECK(length(CAST(body AS BLOB))<=360000);
-- statement
UPDATE posts SET body=legacy_body;
-- statement
ALTER TABLE posts DROP COLUMN legacy_body;
-- statement
ALTER TABLE posts ADD COLUMN pin_rank INTEGER NOT NULL DEFAULT 0 CHECK(pin_rank BETWEEN 0 AND 1000);
-- statement
ALTER TABLE posts ADD COLUMN content_hash TEXT CHECK(length(content_hash)=64);
-- statement
CREATE INDEX posts_pinned ON posts(pin_rank DESC,created_at DESC,id DESC) WHERE state='approved' AND pin_rank>0 AND displayed_identity_id IS NOT NULL;
-- statement
CREATE INDEX posts_repeat ON posts(author_id,content_hash,created_at DESC) WHERE state='approved';
-- statement
CREATE TABLE community_reports(
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
  reporter_id TEXT NOT NULL REFERENCES members(id),
  target_kind TEXT NOT NULL CHECK(target_kind IN ('post','member')),
  target_id TEXT NOT NULL CHECK(length(target_id)=36),
  target_member_id TEXT NOT NULL REFERENCES members(id),
  target_version INTEGER NOT NULL CHECK(target_version>0),
  category TEXT NOT NULL CHECK(category IN ('spam','disruption','harassment','inappropriate','privacy','impersonation','copyright','other')),
  detail TEXT NOT NULL CHECK(length(detail)<=500),
  created_at INTEGER NOT NULL CHECK(created_at>=0),
  CHECK(reporter_id<>target_member_id),
  UNIQUE(reporter_id,target_kind,target_id)
) STRICT;
