export function memberVisible(member: string, viewer = '?') {
  return `EXISTS(SELECT 1 FROM members m WHERE m.id=${member} AND m.state='active')
    AND NOT EXISTS(SELECT 1 FROM blocks WHERE blocker_id=${viewer} AND blocked_id=${member})
    AND NOT EXISTS(SELECT 1 FROM blocks WHERE blocked_id=${viewer} AND blocker_id=${member})`;
}

export function postVisible(alias: string, viewer = '?', now = '?') {
  return `${alias}.state='approved' AND ${alias}.publish_at<=${now} AND ${memberVisible(alias+'.author_id',viewer)}`;
}

export const viewer = '(SELECT actor FROM visibility)';
export const requestTime = '(SELECT at FROM visibility)';
export const visibilityCte = 'WITH visibility(actor,at) AS (VALUES (?,?))';

export function acceptedComment(alias: string, asViewer = viewer) {
  return `${alias}.state='approved' AND ${memberVisible(alias+'.author_id',asViewer)}
    AND (${alias}.parent_id IS NULL OR EXISTS (
      SELECT 1 FROM comments root WHERE root.id=${alias}.parent_id
      AND root.state IN ('approved','deleted') AND ${memberVisible('root.author_id',asViewer)}))`;
}

export function visibleThread(alias: string) {
  return `(${acceptedComment(alias)} OR (${alias}.state='deleted' AND ${alias}.parent_id IS NULL
    AND ${memberVisible(alias+'.author_id',viewer)}
    AND EXISTS(SELECT 1 FROM comments child WHERE child.post_id=${alias}.post_id
      AND child.parent_id=${alias}.id AND child.state='approved' AND ${memberVisible('child.author_id',viewer)})))`;
}
