CREATE INDEX collection_entries_photo ON collection_entries(photo_id) WHERE photo_id IS NOT NULL;
-- statement
CREATE INDEX official_identities_member ON official_identities(member_id,active,id);
