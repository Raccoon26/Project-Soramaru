
CREATE TABLE posts (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  author_id TEXT NOT NULL REFERENCES members(id),
  displayed_identity_id TEXT,
  quote_post_id TEXT REFERENCES posts(id) ON DELETE SET NULL,
  body TEXT NOT NULL CHECK(length(body) <= 10000),
  state TEXT NOT NULL CHECK(state IN ('draft','approved','hidden','deleted')),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),
  publish_at INTEGER NOT NULL CHECK(publish_at >= 0),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  CHECK(quote_post_id IS NULL OR quote_post_id <> id),
  FOREIGN KEY(displayed_identity_id,author_id) REFERENCES official_identities(id,member_id)
) STRICT;
-- statement
CREATE INDEX posts_feed ON posts(state, created_at DESC, id DESC);
-- statement
CREATE INDEX posts_author ON posts(author_id, state, created_at DESC, id DESC);
-- statement
CREATE INDEX posts_due ON posts(state, publish_at, id);
-- statement
CREATE TABLE comments (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  post_id TEXT NOT NULL REFERENCES posts(id),
  parent_id TEXT,
  author_id TEXT NOT NULL REFERENCES members(id),
  body TEXT NOT NULL CHECK(length(body) <= 10000),
  state TEXT NOT NULL CHECK(state IN ('approved','hidden','deleted')),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  UNIQUE(post_id, id),
  CHECK(parent_id IS NULL OR parent_id <> id),
  FOREIGN KEY(post_id, parent_id) REFERENCES comments(post_id, id)
) STRICT;
-- statement
CREATE INDEX comments_thread ON comments(post_id, parent_id, created_at, id);
-- statement
CREATE TRIGGER comments_depth BEFORE INSERT ON comments
WHEN NEW.parent_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM comments WHERE post_id = NEW.post_id AND id = NEW.parent_id
    AND parent_id IS NULL AND state = 'approved'
)
BEGIN SELECT RAISE(ABORT, 'invalid_parent_comment'); END;
-- statement
CREATE TRIGGER comments_no_move BEFORE UPDATE OF parent_id, post_id ON comments
BEGIN SELECT RAISE(ABORT, 'comment_parent_immutable'); END;
-- statement
CREATE TABLE tags (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  normalized TEXT NOT NULL UNIQUE CHECK(length(normalized) BETWEEN 1 AND 48),
  label TEXT NOT NULL CHECK(length(label) BETWEEN 1 AND 48)
) STRICT;
-- statement
CREATE TABLE post_tags (
  post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id),
  PRIMARY KEY(post_id, tag_id)
) STRICT;
-- statement
CREATE INDEX post_tags_reverse ON post_tags(tag_id, post_id);
-- statement
CREATE TABLE blocks (
  blocker_id TEXT NOT NULL REFERENCES members(id),
  blocked_id TEXT NOT NULL REFERENCES members(id),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  CHECK(blocker_id <> blocked_id),
  PRIMARY KEY(blocker_id, blocked_id)
) STRICT;
-- statement
CREATE INDEX blocks_reverse ON blocks(blocked_id, blocker_id);
-- statement
CREATE TABLE reactions (
  member_id TEXT NOT NULL REFERENCES members(id),
  post_id TEXT REFERENCES posts(id),
  comment_id TEXT REFERENCES comments(id),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  CHECK((post_id IS NULL) <> (comment_id IS NULL)),
  UNIQUE(member_id, post_id),
  UNIQUE(member_id, comment_id)
) STRICT;
-- statement
CREATE TABLE badge_catalog (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  label TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('draft','approved','retired'))
) STRICT;
-- statement
CREATE TABLE badge_awards (
  member_id TEXT NOT NULL REFERENCES members(id),
  badge_id TEXT NOT NULL REFERENCES badge_catalog(id),
  awarded_at INTEGER NOT NULL CHECK(awarded_at >= 0),
  PRIMARY KEY(member_id, badge_id)
) STRICT;
-- statement
CREATE TABLE applied_badges (
  member_id TEXT PRIMARY KEY NOT NULL,
  badge_id TEXT NOT NULL,
  FOREIGN KEY(member_id,badge_id) REFERENCES badge_awards(member_id,badge_id) ON DELETE CASCADE
) STRICT;
