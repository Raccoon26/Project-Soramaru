ALTER TABLE member_sessions ADD COLUMN device_alias TEXT NOT NULL DEFAULT '端末'
  CHECK(length(device_alias) BETWEEN 1 AND 40);
-- statement
ALTER TABLE member_sessions ADD COLUMN device_os TEXT NOT NULL DEFAULT 'other'
  CHECK(device_os IN ('ios','android','other'));
-- statement
ALTER TABLE member_sessions ADD COLUMN firebase_auth_at INTEGER NOT NULL DEFAULT 0 CHECK(firebase_auth_at>=0);
-- statement
ALTER TABLE member_sessions ADD COLUMN absolute_expires_at INTEGER CHECK(absolute_expires_at>=expires_at);
-- statement
ALTER TABLE member_sessions ADD COLUMN renewed_at INTEGER CHECK(renewed_at>=created_at);
-- statement
CREATE INDEX sessions_expiry ON member_sessions(expires_at,id);
-- statement
ALTER TABLE member_profiles ADD COLUMN avatar_media_id TEXT REFERENCES media_objects(id);
-- statement
ALTER TABLE member_profiles ADD COLUMN collection_public INTEGER NOT NULL DEFAULT 0 CHECK(collection_public IN (0,1));
-- statement
ALTER TABLE member_profiles ADD COLUMN configured_at INTEGER CHECK(configured_at>=0);
-- statement
CREATE TABLE policy_acceptances (
  member_id TEXT NOT NULL REFERENCES members(id),
  kind TEXT NOT NULL CHECK(kind IN ('terms','privacy','guidelines')),
  version TEXT NOT NULL CHECK(length(version) BETWEEN 1 AND 40),
  accepted_at INTEGER NOT NULL CHECK(accepted_at>=0),
  PRIMARY KEY(member_id,kind,version)
) STRICT;
-- statement
CREATE TABLE content_operator_grants (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
  member_id TEXT NOT NULL REFERENCES members(id),
  granted_by TEXT NOT NULL REFERENCES members(id),
  approved_by TEXT NOT NULL REFERENCES members(id),
  starts_at INTEGER NOT NULL CHECK(starts_at>=0),
  ends_at INTEGER NOT NULL CHECK(ends_at>starts_at),
  revoked_at INTEGER CHECK(revoked_at>=starts_at),
  CHECK(member_id<>granted_by AND member_id<>approved_by AND granted_by<>approved_by)
) STRICT;
-- statement
CREATE UNIQUE INDEX operator_one_live ON content_operator_grants(member_id) WHERE revoked_at IS NULL;
-- statement
CREATE TABLE membership_audit (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
  actor_id TEXT REFERENCES members(id),
  action TEXT NOT NULL CHECK(action IN ('session_issue','session_renew','session_revoke','revoke_all','policies','profile','deletion_begin','grant','grant_revoke')),
  subject_id TEXT NOT NULL CHECK(length(subject_id)=36),
  created_at INTEGER NOT NULL CHECK(created_at>=0)
) STRICT;
-- statement
CREATE INDEX member_audit_time ON membership_audit(created_at,id);
-- statement
CREATE TRIGGER member_audit_no_edit BEFORE UPDATE ON membership_audit
BEGIN SELECT RAISE(ABORT,'audit_append_only'); END;
-- statement
CREATE TRIGGER member_audit_no_delete BEFORE DELETE ON membership_audit
BEGIN SELECT RAISE(ABORT,'audit_append_only'); END;
