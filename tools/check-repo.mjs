import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, URL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' });
const read = (path) => readFileSync(join(root, path), 'utf8');

const documents = [
  'README.md', 'PROJECT_STATUS.md', 'MASTER_REQUIREMENTS.md', 'DEV_ROADMAP.md',
  'REQUIREMENTS_MATRIX.md', 'UI_REFERENCE.md', 'DESIGN_SYSTEM.md',
  'SCREEN_INVENTORY.md', 'ARCHITECTURE.md', 'DATABASE_DESIGN.md', 'API_DESIGN.md',
  'COST_POLICY.md', 'SECURITY_POLICY.md', 'CONTENT_GUIDE.md', 'RIGHTS_STATUS.md',
  'TEST_REPORT.md', 'RELEASE_CHECKLIST.md', 'OPERATION_GUIDE.md', 'AGENTS.md',
  'NAVIGATION_GUIDE.md', 'BACKEND_GUIDE.md', 'DATABASE_MIGRATION_GUIDE.md',
  'COST_CONTROL_GUIDE.md', 'BACKUP_RESTORE_GUIDE.md',
  'FAN_COMMUNITY_GUIDE.md', 'POST_LIFECYCLE_GUIDE.md', 'LOCAL_DRAFT_GUIDE.md', 'MODERATION_GUIDE.md',
  'AUTHENTICATION_GUIDE.md', 'FIREBASE_EMULATOR_GUIDE.md', 'SESSION_MANAGEMENT_GUIDE.md', 'MEMBER_LIFECYCLE_GUIDE.md',
  'MEDIA_UPLOAD_GUIDE.md', 'IMAGE_PROCESSING_GUIDE.md', 'MEDIA_ACCESS_GUIDE.md', 'GALLERY_GUIDE.md', 'MEDIA_LIFECYCLE_GUIDE.md',
  'COMMENT_GUIDE.md', 'REACTION_GUIDE.md', 'STAMP_GUIDE.md', 'INTERACTION_EVENT_GUIDE.md',
  'SEARCH_GUIDE.md', 'TAG_DISCOVERY_GUIDE.md', 'FAVORITES_GUIDE.md', 'COLLECTION_GUIDE.md',
  'RECENT_CONTENT_GUIDE.md', 'DATA_RETENTION_GUIDE.md',
];
const rows = (filename, pattern) =>
  read(filename).split(/\r?\n/).filter((line) => pattern.test(line))
    .map((line) => line.split('|').slice(1, -1).map((value) => value.trim()));

const master = rows('MASTER_REQUIREMENTS.md', /^\| [A-Z]+-\d+ \|/);
const matrix = rows('REQUIREMENTS_MATRIX.md', /^\| [A-Z]+-\d+ \|/);
const masterIds = master.map(([id]) => id);
assert.ok(masterIds.length >= 100, 'Requirements list is unexpectedly short');
assert.equal(new Set(masterIds).size, masterIds.length, 'Duplicate master requirement ID');
assert.deepEqual(matrix.map(([id]) => id), masterIds, 'Master and matrix IDs differ');

const screenIds = new Set(rows('SCREEN_INVENTORY.md', /^\| [A-Z]\d\d \|/).map(([id]) => id));
const rightIds = new Set(rows('RIGHTS_STATUS.md', /^\| R\d\d \|/).map(([id]) => id));
for (const [id, phase, screen, proof, right, status] of matrix) {
  assert.match(phase, /^\d\d(?:[–/]\d\d)*$/, id);
  assert.ok(proof && status, 'Missing verification or status for ' + id);
  for (const [field, ids] of [[screen, screenIds], [right, rightIds]]) {
    assert.ok(field === '—' || field.split(' ').every((value) => ids.has(value)),
      'Unknown traceability reference for ' + id + ': ' + field);
  }
}

const refs = rows('UI_REFERENCE.md', /^\| \d{4}(?:\(1\))? \|/);
assert.equal(refs.length, 53, 'Reference inventory count');
assert.equal(new Set(refs.map(([id]) => id)).size, 53, 'Duplicate reference ID');
for (const [id, dimensions, screens] of refs) {
  assert.match(dimensions, /^\d+×\d+$/, 'Missing image dimensions: ' + id);
  assert.ok(screens.split('/').every((value) => screenIds.has(value)),
    'Unknown screen in source ' + id);
}

const ignored = ['references/verification-probe.mp4', '.local/verification-probe',
  'services/api/.env', 'apps/mobile/android/key.properties'];
for (const file of ignored) {
  assert.equal(git('check-ignore', '--no-index', file).trim(), file);
}
const paths = git('ls-files', '-z').split('\0').filter(Boolean);
const sdkImages = /^apps\/mobile\/(android\/app\/src\/main\/res\/mipmap-[a-z]+\/ic_launcher\.png|ios\/Runner\/Assets\.xcassets\/(AppIcon\.appiconset|LaunchImage\.imageset)\/[a-z0-9@_.-]+\.png)$/i;
const syntheticGoldens = new Set([
  'apps/mobile/test/goldens/category-and-empty.png',
  'apps/mobile/test/goldens/fan-feed.png',
  'apps/mobile/test/goldens/linux/category-and-empty.png',
  'apps/mobile/test/goldens/linux/fan-feed.png',
]);
for (const path of paths) {
  assert.doesNotMatch(path, /^(references|\.local)\/|\.(pem|p12|p8|jks|keystore|sqlite3?|mobileprovision)$/i,
    'Local data or credential path: ' + path);
  if (!path.endsWith('.example')) {
    assert.doesNotMatch(path, /(^|\/)(\.env(\..+)?|\.dev\.vars(\..+)?|key\.properties|google-services\.json|GoogleService-Info\.plist|firebase_options\.dart)$/i,
      'Credential configuration path: ' + path);
  }
  if (/\.(png|jpe?g|heic|webp|gif|mp4|mov|m4a|wav|zip)$/i.test(path)) {
    assert.ok(sdkImages.test(path) || syntheticGoldens.has(path),
      'Review media before changing the asset allowlist: ' + path);
  }
}

for (const filename of documents) {
  for (const [, link] of read(filename).matchAll(/\]\((?!https?:\/\/|#)([^)\s]+\.md)(?:#[^)]+)?\)/g)) {
    read(join(dirname(filename), link));
  }
}
globalThis.console.log('Verified ' + masterIds.length + ' requirement IDs, '
  + refs.length + ' source image entries, ' + documents.length + ' documents and Git guardrails.');
