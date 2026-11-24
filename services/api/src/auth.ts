
import { isId, query } from './platform.ts';
import type { Database, QueryMeta } from './platform.ts';
import { HttpError } from './http.ts';

export type Role = 'member' | 'artist' | 'administrator';
export interface VerifiedCredential { firebaseUid: string; sessionDigest: string }
export type Verifier = (token: string) => Promise<VerifiedCredential | null>;

export interface Actor {
  id: string;
  sessionId: string;
  role: Role;
}

export const denyUnconfigured: Verifier = () => Promise.resolve(null);

export async function authenticate(db: Database, authorization: string | null, verify: Verifier, now: number,
  observe?: (meta: QueryMeta) => void): Promise<Actor> {
  const token = authorization?.match(/^Bearer ([A-Za-z0-9._~-]{1,2048})$/)?.[1];
  const credential = token ? await verify(token) : null;
  if (!credential || !/^[a-f0-9]{64}$/.test(credential.sessionDigest)) throw new HttpError(401, 'authentication_required');
  const result = await query(db, `
    SELECT m.id,s.id AS session_id,m.state,coalesce(g.role,'member') AS role
    FROM member_sessions AS s JOIN members AS m ON m.id=s.member_id
    LEFT JOIN role_grants AS g ON g.member_id=m.id AND g.revoked_at IS NULL
      AND g.starts_at<=? AND (g.ends_at IS NULL OR g.ends_at>?)
    WHERE m.auth_uid=? AND s.session_hash=? AND s.expires_at>?
      AND s.revoked_at IS NULL AND s.created_at>=m.revoked_before
  `, now, now, credential.firebaseUid, credential.sessionDigest, now)
    .all<{ id: string; session_id: string; state: string; role: Role }>();
  observe?.(result.meta);
  const row = result.results[0];
  if (!row) throw new HttpError(401, 'authentication_required');
  if (row.state !== 'active') throw new HttpError(403, 'access_denied');
  return { id: row.id, sessionId: row.session_id, role: row.role };
}

export function requireRole(actor: Actor, role: Role) {
  if (actor.role !== role) throw new HttpError(403, 'access_denied');
}

export function requireOwner(actor: Actor, owner: string) {
  if (!isId(owner) || actor.id !== owner) throw new HttpError(404, 'not_found');
}
