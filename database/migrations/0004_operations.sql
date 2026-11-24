
CREATE TABLE usage_windows (
  name TEXT PRIMARY KEY NOT NULL CHECK(name = 'service'),
  day TEXT NOT NULL DEFAULT '',
  month TEXT NOT NULL DEFAULT '',
  counters TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(counters)),
  snapshot_at INTEGER NOT NULL DEFAULT 0 CHECK(snapshot_at >= 0),
  snapshot TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(snapshot))
) STRICT;
-- statement
INSERT INTO usage_windows(name) VALUES ('service');
-- statement
CREATE TABLE feature_flags (
  name TEXT PRIMARY KEY NOT NULL CHECK(name IN (
    'maintenance_mode','registration_enabled','posting_enabled','comments_enabled',
    'image_upload_enabled','audio_upload_enabled','media_grants_enabled','direct_media_enabled',
    'downloads_enabled','search_enabled','notifications_enabled','scheduled_jobs_enabled'
  )),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
  version INTEGER NOT NULL DEFAULT 1 CHECK(version >= 1)
) STRICT;
-- statement
INSERT INTO feature_flags VALUES
  ('maintenance_mode',0,0,1),('registration_enabled',1,0,1),('posting_enabled',1,0,1),
  ('comments_enabled',1,0,1),('image_upload_enabled',1,0,1),('audio_upload_enabled',1,0,1),
  ('media_grants_enabled',1,0,1),('direct_media_enabled',0,0,1),('downloads_enabled',1,0,1),
  ('search_enabled',1,0,1),('notifications_enabled',1,0,1),('scheduled_jobs_enabled',1,0,1);
-- statement
CREATE TABLE rate_limits (
  scope TEXT PRIMARY KEY NOT NULL,
  window INTEGER NOT NULL CHECK(window >= 0),
  count INTEGER NOT NULL CHECK(count > 0)
) STRICT;
-- statement
CREATE INDEX rate_expiry ON rate_limits(window,scope);
-- statement
CREATE TABLE scheduled_jobs (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  kind TEXT NOT NULL,
  dedupe_key TEXT NOT NULL UNIQUE,
  payload TEXT NOT NULL CHECK(json_valid(payload) AND length(payload) <= 8192),
  required INTEGER NOT NULL DEFAULT 0 CHECK(required IN (0,1)),
  state TEXT NOT NULL CHECK(state IN ('ready','leased','done','dead')),
  run_at INTEGER NOT NULL CHECK(run_at >= 0),
  lease_until INTEGER,
  lease_token TEXT,
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
  max_attempts INTEGER NOT NULL DEFAULT 5 CHECK(max_attempts BETWEEN 1 AND 10 AND attempts <= max_attempts),
  last_error TEXT,
  CHECK((state = 'leased') = (lease_token IS NOT NULL AND lease_until IS NOT NULL))
) STRICT;
-- statement
CREATE INDEX jobs_due ON scheduled_jobs(state,run_at,id) WHERE state='ready';
-- statement
CREATE INDEX jobs_lease ON scheduled_jobs(state,lease_until,id) WHERE state='leased';
-- statement
CREATE TABLE outbox (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  dedupe_key TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  event_payload TEXT NOT NULL CHECK(json_valid(event_payload) AND length(event_payload) <= 8192),
  job_id TEXT NOT NULL UNIQUE REFERENCES scheduled_jobs(id),
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  delivered_at INTEGER CHECK(delivered_at >= created_at)
) STRICT;
-- statement
CREATE TABLE idempotency_keys (
  actor_id TEXT NOT NULL REFERENCES members(id),
  operation TEXT NOT NULL,
  request_key TEXT NOT NULL,
  fingerprint TEXT NOT NULL CHECK(length(fingerprint) = 64),
  result TEXT NOT NULL CHECK(json_valid(result) AND length(result) <= 8192),
  expires_at INTEGER NOT NULL CHECK(expires_at >= 0),
  PRIMARY KEY(actor_id,operation,request_key)
) STRICT;
-- statement
CREATE INDEX idempotency_expiry ON idempotency_keys(expires_at);
-- statement
CREATE TABLE audit_events (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  actor_id TEXT REFERENCES members(id),
  event TEXT NOT NULL CHECK(event IN ('reservation','expiry','access_denied','budget_denied','job_done','job_failure','deletion_replay')),
  result TEXT NOT NULL CHECK(result IN ('allowed','denied','completed','retry','failed')),
  created_at INTEGER NOT NULL CHECK(created_at >= 0)
) STRICT;
-- statement
CREATE INDEX audit_created ON audit_events(created_at,id);
-- statement
CREATE TRIGGER audit_no_edit BEFORE UPDATE ON audit_events
BEGIN SELECT RAISE(ABORT,'audit_append_only'); END;
-- statement
CREATE TRIGGER audit_no_delete BEFORE DELETE ON audit_events
BEGIN SELECT RAISE(ABORT,'audit_append_only'); END;
-- statement
CREATE TABLE notifications (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  recipient_id TEXT REFERENCES members(id),
  event_kind TEXT NOT NULL,
  target_kind TEXT NOT NULL,
  target_id TEXT NOT NULL CHECK(length(target_id) = 36),
  dedupe_key TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL CHECK(created_at >= 0),
  read_at INTEGER CHECK(recipient_id IS NOT NULL AND read_at >= created_at)
) STRICT;
-- statement
CREATE INDEX inbox_created ON notifications(recipient_id,created_at DESC,id DESC);
-- statement
CREATE INDEX inbox_unread ON notifications(recipient_id,read_at,created_at DESC,id DESC) WHERE recipient_id IS NOT NULL;
-- statement
CREATE TABLE notification_reads (
  member_id TEXT NOT NULL REFERENCES members(id),
  notification_id TEXT NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  read_at INTEGER NOT NULL CHECK(read_at >= 0),
  PRIMARY KEY(member_id,notification_id)
) STRICT;
