CREATE INDEX session_devices_recent ON member_sessions(member_id,created_at DESC,id DESC);
-- statement
CREATE TRIGGER role_membership_audit AFTER INSERT ON role_grants
BEGIN
  INSERT INTO membership_audit VALUES (NEW.id,NEW.granted_by,'grant',NEW.member_id,NEW.starts_at);
END;
-- statement
CREATE TRIGGER role_membership_revoke_audit AFTER UPDATE OF revoked_at ON role_grants
WHEN OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
BEGIN
  INSERT INTO membership_audit VALUES (lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4'||
    substr(lower(hex(randomblob(2))),2)||'-8'||substr(lower(hex(randomblob(2))),2)||'-'||lower(hex(randomblob(6))),
    NULL,'grant_revoke',NEW.member_id,NEW.revoked_at);
END;
-- statement
CREATE TRIGGER operator_membership_audit AFTER INSERT ON content_operator_grants
BEGIN
  INSERT INTO membership_audit VALUES (NEW.id,NEW.granted_by,'grant',NEW.member_id,NEW.starts_at);
END;
-- statement
CREATE TRIGGER operator_membership_revoke_audit AFTER UPDATE OF revoked_at ON content_operator_grants
WHEN OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
BEGIN
  INSERT INTO membership_audit VALUES (lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4'||
    substr(lower(hex(randomblob(2))),2)||'-8'||substr(lower(hex(randomblob(2))),2)||'-'||lower(hex(randomblob(6))),
    NULL,'grant_revoke',NEW.member_id,NEW.revoked_at);
END;
