
CREATE TABLE member_numbers (
  number TEXT PRIMARY KEY NOT NULL CHECK(length(number) BETWEEN 8 AND 24),
  issued_at INTEGER NOT NULL CHECK(issued_at >= 0)
) STRICT;
-- statement
CREATE TRIGGER member_numbers_no_delete BEFORE DELETE ON member_numbers
BEGIN SELECT RAISE(ABORT, 'number_ledger_immutable'); END;
-- statement
CREATE TRIGGER member_numbers_no_update BEFORE UPDATE ON member_numbers
BEGIN SELECT RAISE(ABORT, 'number_ledger_immutable'); END;
-- statement
CREATE TABLE members (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  auth_uid TEXT UNIQUE CHECK(length(auth_uid) BETWEEN 1 AND 128),
  member_no TEXT NOT NULL UNIQUE REFERENCES member_numbers(number),
  state TEXT NOT NULL CHECK(state IN ('unverified','terms_required','active','inactive','suspended','deleting','deleted')),
  joined_at INTEGER NOT NULL CHECK(joined_at >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= joined_at),
  revoked_before INTEGER NOT NULL DEFAULT 0 CHECK(revoked_before >= 0),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  CHECK(state NOT IN ('deleting','deleted') OR revoked_before > 0)
) STRICT;
-- statement
CREATE TRIGGER members_no_delete BEFORE DELETE ON members
BEGIN SELECT RAISE(ABORT, 'member_tombstone_required'); END;
-- statement
CREATE TRIGGER members_no_number_change BEFORE UPDATE OF member_no ON members
BEGIN SELECT RAISE(ABORT, 'number_immutable'); END;
-- statement
CREATE TRIGGER members_terminal_state BEFORE UPDATE OF state ON members
WHEN (OLD.state = 'deleted' AND NEW.state <> 'deleted') OR
     (OLD.state = 'deleting' AND NEW.state NOT IN ('deleting','deleted'))
BEGIN SELECT RAISE(ABORT, 'member_terminal_state'); END;
-- statement
CREATE INDEX members_state_joined ON members(state, joined_at, id);
-- statement
CREATE TABLE member_profiles (
  member_id TEXT PRIMARY KEY NOT NULL REFERENCES members(id),
  nickname TEXT NOT NULL CHECK(length(nickname) BETWEEN 1 AND 32),
  biography TEXT NOT NULL DEFAULT '' CHECK(length(biography) <= 500),
  birth_month INTEGER CHECK(birth_month BETWEEN 1 AND 12),
  birth_day INTEGER CHECK(birth_day BETWEEN 1 AND 31),
  updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1),
  CHECK((birth_month IS NULL) = (birth_day IS NULL))
) STRICT;
-- statement
CREATE TABLE terms_acceptances (
  member_id TEXT NOT NULL REFERENCES members(id),
  document_version TEXT NOT NULL CHECK(length(document_version) BETWEEN 1 AND 40),
  accepted_at INTEGER NOT NULL CHECK(accepted_at >= 0),
  PRIMARY KEY(member_id, document_version)
) STRICT;
-- statement
CREATE TABLE member_sessions (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  member_id TEXT NOT NULL REFERENCES members(id),
  session_hash TEXT NOT NULL UNIQUE CHECK(length(session_hash) = 64),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  expires_at INTEGER NOT NULL CHECK(expires_at > created_at),
  revoked_at INTEGER CHECK(revoked_at >= created_at),
  last_seen INTEGER NOT NULL CHECK(last_seen >= created_at)
) STRICT;
-- statement
CREATE INDEX sessions_member ON member_sessions(member_id, revoked_at, created_at);
-- statement
CREATE TABLE role_grants (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  member_id TEXT NOT NULL REFERENCES members(id),
  role TEXT NOT NULL CHECK(role IN ('artist','administrator')),
  granted_by TEXT NOT NULL REFERENCES members(id),
  approved_by TEXT NOT NULL REFERENCES members(id),
  starts_at INTEGER NOT NULL CHECK(starts_at >= 0),
  ends_at INTEGER CHECK(ends_at > starts_at),
  revoked_at INTEGER CHECK(revoked_at >= starts_at),
  CHECK(member_id <> granted_by AND member_id <> approved_by AND granted_by <> approved_by)
) STRICT;
-- statement
CREATE UNIQUE INDEX role_one_live ON role_grants(member_id) WHERE revoked_at IS NULL;
-- statement
CREATE TABLE official_identities (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  member_id TEXT NOT NULL REFERENCES members(id),
  display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
  active INTEGER NOT NULL DEFAULT 0 CHECK(active IN (0,1)),
  UNIQUE(id, member_id)
) STRICT;
-- statement
CREATE TABLE staff_credentials (
  id TEXT PRIMARY KEY NOT NULL,
  member_id TEXT NOT NULL REFERENCES members(id),
  credential_id TEXT NOT NULL UNIQUE,
  public_key TEXT NOT NULL,
  sign_count INTEGER NOT NULL DEFAULT 0 CHECK(sign_count >= 0),
  revoked_at INTEGER
) STRICT;
-- statement
CREATE TABLE staff_challenges (
  digest TEXT PRIMARY KEY NOT NULL CHECK(length(digest) = 64),
  member_id TEXT NOT NULL REFERENCES members(id),
  expires_at INTEGER NOT NULL CHECK(expires_at >= 0),
  consumed_at INTEGER CHECK(consumed_at <= expires_at)
) STRICT;
-- statement
CREATE TABLE deletion_requests (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  member_id TEXT NOT NULL UNIQUE REFERENCES members(id),
  state TEXT NOT NULL CHECK(state IN ('requested','revoked','scrubbing','completed')),
  requested_at INTEGER NOT NULL CHECK(requested_at >= 0),
  updated_at INTEGER NOT NULL CHECK(updated_at >= requested_at)
) STRICT;
