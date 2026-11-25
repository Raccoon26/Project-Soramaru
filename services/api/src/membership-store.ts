import { HttpError } from './http.ts';
import { digest,isId,query } from './platform.ts';
import type { Database } from './platform.ts';
import { base64url } from './firebase.ts';
import type { FirebaseIdentity } from './firebase.ts';
import { policyDocuments,policyVersion } from './membership-policy.ts';
import { enqueue } from './jobs.ts';

const idle=8*3_600_000;
const absolute=30*86_400_000;
const recent=300_000;
type State='unverified'|'terms_required'|'active'|'inactive'|'suspended'|'deleting'|'deleted';
type MemberRole='member'|'artist'|'content_operator'|'administrator';
interface Member {
  id: string; member_no: string; joined_at: number; state: State; revoked_before: number;
  nickname: string; biography: string; birth_month: number|null; birth_day: number|null;
  avatar_media_id: string|null; collection_public: number; configured_at: number|null;
  profile_version: number; accepted: number; role: MemberRole;
}
interface Device {
  id: string; device_alias: string; device_os: string; created_at: number;
  last_seen: number; expires_at: number; revoked_at: number|null;
  firebase_auth_at: number; absolute_expires_at: number|null;
}

export const opaquePattern=/^[A-Za-z0-9_-]{43}$/;
const forbiddenText=/[\p{Cc}\u200B\u202A-\u202E\u2066-\u2069\uFEFF<>]/u;
const reservedNickname=/(?:徳井青空|そらまる|公式|運営|管理者|administrator|official|moderator|soramaru|support|サポート)/iu;

export function inputText(value: unknown,min: number,max: number) {
  if (typeof value!=='string'||forbiddenText.test(value)) throw new HttpError(400,'invalid_request');
  const cleaned=value.trim();
  const count=[...cleaned].length;
  if (count<min||count>max) throw new HttpError(400,'invalid_request');
  return cleaned;
}

function memberQuery(db: Database,uid: string,now: number) {
  return query(db,`
    SELECT m.id,m.member_no,m.joined_at,m.state,m.revoked_before,
      p.nickname,p.biography,p.birth_month,p.birth_day,p.avatar_media_id,p.collection_public,p.configured_at,
      p.version AS profile_version,
      (SELECT count(*) FROM policy_acceptances a WHERE a.member_id=m.id AND a.version=?1) AS accepted,
      CASE WHEN g.role='artist' AND EXISTS(SELECT 1 FROM official_identities i WHERE i.member_id=m.id AND i.active=1)
             THEN 'artist'
           WHEN g.role='administrator' THEN 'administrator'
           WHEN g.id IS NULL AND EXISTS(SELECT 1 FROM content_operator_grants op
             WHERE op.member_id=m.id AND op.revoked_at IS NULL AND op.starts_at<=?2 AND op.ends_at>?2)
             THEN 'content_operator' ELSE 'member' END AS role
    FROM members m JOIN member_profiles p ON p.member_id=m.id
    LEFT JOIN role_grants g ON g.member_id=m.id AND g.revoked_at IS NULL
      AND g.starts_at<=?2 AND (g.ends_at IS NULL OR g.ends_at>?2)
    WHERE m.auth_uid=?3
  `,policyVersion,now,uid);
}

function denyBlocked(state: State) {
  if (state==='suspended') throw new HttpError(403,'account_suspended');
  if (state==='deleting'||state==='deleted') throw new HttpError(403,'account_deleting');
  if (state==='inactive') throw new HttpError(403,'access_denied');
}

function phaseFor(member: Member,identity: FirebaseIdentity) {
  denyBlocked(member.state);
  if (!identity.verifiedEmail) return 'unverified';
  if (member.accepted!==policyDocuments.length) return 'terms_required';
  return member.configured_at===null?'profile_required':'active';
}

function profile(member: Member) {
  return {id:member.id,memberNumber:member.member_no,joinedAt:member.joined_at,nickname:member.nickname,
    biography:member.biography,birthMonth:member.birth_month,birthDay:member.birth_day,
    avatarMediaId:member.avatar_media_id,collectionPublic:member.collection_public===1,version:member.profile_version};
}

function deviceView(row: Device,current: string,now: number) {
  return {id:row.id,alias:row.device_alias,os:row.device_os,createdAt:row.created_at,lastSeen:row.last_seen,
    expiresAt:row.expires_at,current:row.id===current,status:row.revoked_at!==null?'revoked':row.expires_at<=now?'expired':'active'};
}

export class MembershipStore {
  private readonly db: Database;
  private readonly now: number;
  private readonly sessionKey: CryptoKey;

  constructor(db: Database,now: number,sessionKey: CryptoKey) {
    this.db=db;
    this.now=now;
    this.sessionKey=sessionKey;
  }

  private async find(identity: FirebaseIdentity) {
    return memberQuery(this.db,identity.uid,this.now).first<Member>();
  }

  private async ensure(identity: FirebaseIdentity): Promise<Member> {
    const db=this.db;
    const found=await this.find(identity);
    if (found) return found;
    for (let i=0;i<3;i++) {
      const id=crypto.randomUUID();
      const number='SM-'+Array.from(crypto.getRandomValues(new Uint8Array(7)),x=>x.toString(16).padStart(2,'0')).join('').toUpperCase();
      try {
        await db.batch([
          query(db,`INSERT INTO member_numbers SELECT ?1,?2 WHERE NOT EXISTS(SELECT 1 FROM members WHERE auth_uid=?3)`,
            number,this.now,identity.uid),
          query(db,`INSERT INTO members(id,member_no,auth_uid,state,joined_at,updated_at)
            SELECT ?1,?2,?3,?4,?5,?5 WHERE NOT EXISTS(SELECT 1 FROM members WHERE auth_uid=?3)`,
            id,number,identity.uid,identity.verifiedEmail?'terms_required':'unverified',this.now),
          query(db,`INSERT INTO member_profiles(member_id,nickname,updated_at)
            SELECT id,'メンバー',?1 FROM members WHERE auth_uid=?2 ON CONFLICT(member_id) DO NOTHING`,this.now,identity.uid),
        ]);
        const member=await this.find(identity);
        if (member) return member;
      } catch (error) {
        if (i===2) throw error;
      }
    }
    throw new HttpError(503,'unavailable',15);
  }

  async issue(identity: FirebaseIdentity,nonce: string,alias: string,os: string) {
    if (!opaquePattern.test(nonce)||!['ios','android','other'].includes(os)) throw new HttpError(400,'invalid_request');
    if (this.now-identity.authAt>recent) throw new HttpError(401,'recent_auth_required');
    const member=await this.ensure(identity);
    denyBlocked(member.state);
    if (identity.authAt<member.revoked_before) throw new HttpError(401,'authentication_required');
    const material=new TextEncoder().encode(JSON.stringify(['app-session-v1',identity.uid,identity.authAt,nonce]));
    const token=base64url(new Uint8Array(await crypto.subtle.sign('HMAC',this.sessionKey,material)));
    const hash=await digest(token);
    const db=this.db;
    const id=crypto.randomUUID();
    await db.batch([
      query(db,`INSERT INTO member_sessions(id,member_id,session_hash,created_at,expires_at,last_seen,
          device_alias,device_os,firebase_auth_at,absolute_expires_at,renewed_at)
        SELECT ?1,m.id,?2,?3,?4,?3,?5,?6,?7,?8,?3 FROM members m
        WHERE m.id=?9 AND m.revoked_before<=?7 AND m.state IN ('unverified','terms_required','active')
          AND (SELECT count(*) FROM member_sessions s WHERE s.member_id=m.id AND s.revoked_at IS NULL AND s.expires_at>?3)<20
        ON CONFLICT(session_hash) DO NOTHING`,id,hash,this.now,this.now+idle,alias,os,identity.authAt,this.now+absolute,member.id),
      query(db,`INSERT INTO membership_audit SELECT ?1,?2,'session_issue',?3,?4
        WHERE EXISTS(SELECT 1 FROM member_sessions WHERE id=?3)`,crypto.randomUUID(),member.id,id,this.now),
    ]);
    const s=await this.deviceByHash(member.id,hash);
    if (!s) throw new HttpError(409,'device_limit');
    if (s.device_alias!==alias||s.device_os!==os) throw new HttpError(409,'conflict');
    if (s.revoked_at!==null||s.expires_at<=this.now) throw new HttpError(401,'authentication_required');
    const fresh=await this.context(identity,token);
    return {...this.snapshot(fresh),sessionToken:token};
  }

  private deviceByHash(id:string,hash:string) {
    return query(this.db,'SELECT * FROM member_sessions WHERE member_id=? AND session_hash=?',id,hash).first<Device>();
  }

  async context(identity: FirebaseIdentity,credential: string) {
    if (!opaquePattern.test(credential)) throw new HttpError(401,'authentication_required');
    const member=await this.find(identity);
    if (!member) throw new HttpError(401,'authentication_required');
    denyBlocked(member.state);
    const session=await this.deviceByHash(member.id,await digest(credential));
    if (!session||session.revoked_at!==null||session.expires_at<=this.now||
        session.firebase_auth_at<Math.max(member.revoked_before,identity.validSince??0)||identity.authAt<member.revoked_before||
        identity.authAt<session.firebase_auth_at) throw new HttpError(401,'authentication_required');
    return {member,session,identity,phase:phaseFor(member,identity)};
  }

  snapshot(ctx: Awaited<ReturnType<MembershipStore['context']>>) {
    const {member,session,phase}=ctx;
    return {phase,role:phase==='active'?member.role:'member',policyVersion,
      profile:profile(member),session:deviceView(session,session.id,this.now)};
  }

  async renew(actor: MembershipContext) {
    const {member,session}=actor;
    if (session.expires_at-this.now>900_000) return this.snapshot(actor);
    if (session.absolute_expires_at===null||session.absolute_expires_at<=this.now) throw new HttpError(401,'authentication_required');
    await this.db.batch([
      query(this.db,`UPDATE member_sessions SET expires_at=min(absolute_expires_at,?1),renewed_at=?2,
        last_seen=CASE WHEN last_seen<=?2-900000 THEN ?2 ELSE last_seen END
        WHERE id=?3 AND member_id=?4 AND revoked_at IS NULL AND expires_at>?2
        AND expires_at<=?2+900000 AND EXISTS(
          SELECT 1 FROM members WHERE id=?4 AND revoked_before<=firebase_auth_at AND state IN ('unverified','terms_required','active'))`,
        this.now+idle,this.now,session.id,member.id),
      query(this.db,`INSERT INTO membership_audit
        SELECT ?1,?2,'session_renew',?3,?4 WHERE changes()=1`,crypto.randomUUID(),member.id,session.id,this.now),
    ]);
    const current=await query(this.db,'SELECT * FROM member_sessions WHERE id=? AND revoked_at IS NULL AND expires_at>?',
      session.id,this.now).first<Device>();
    if (!current) throw new HttpError(401,'authentication_required');
    return this.snapshot({...actor,session:current});
  }

  async list(ctx: MembershipContext) {
    const active=await query(this.db,`SELECT * FROM member_sessions WHERE member_id=?1
      AND id<>?2 AND revoked_at IS NULL AND expires_at>?3
      ORDER BY created_at DESC,id DESC LIMIT 19`,ctx.member.id,ctx.session.id,this.now).all<Device>();
    const slots=19-active.results.length;
    const recentDevices=slots===0?[]:(await query(this.db,`SELECT * FROM member_sessions WHERE member_id=?1
      AND (revoked_at IS NOT NULL OR expires_at<=?2)
      ORDER BY created_at DESC,id DESC LIMIT ?3`,ctx.member.id,this.now,slots).all<Device>()).results;
    return {items:[ctx.session,...active.results,...recentDevices]
      .map(device=>deviceView(device,ctx.session.id,this.now))};
  }

  async detail(ctx: MembershipContext,id: string) {
    if (!isId(id)) throw new HttpError(404,'not_found');
    const item=await query(this.db,'SELECT * FROM member_sessions WHERE id=? AND member_id=?',id,ctx.member.id).first<Device>();
    if (!item) throw new HttpError(404,'not_found');
    return deviceView(item,ctx.session.id,this.now);
  }

  async revoke(ctx: MembershipContext,id: string) {
    await this.detail(ctx,id);
    if (id!==ctx.session.id&&this.now-ctx.identity.authAt>recent) throw new HttpError(401,'recent_auth_required');
    await this.db.batch([
      query(this.db,'UPDATE member_sessions SET revoked_at=? WHERE id=? AND member_id=? AND revoked_at IS NULL',
        this.now,id,ctx.member.id),
      query(this.db,`INSERT INTO membership_audit SELECT ?1,?2,'session_revoke',?3,?4 WHERE changes()=1`,
        crypto.randomUUID(),ctx.member.id,id,this.now),
    ]);
  }

  async revokeAll(ctx: MembershipContext) {
    if (this.now-ctx.identity.authAt>recent) throw new HttpError(401,'recent_auth_required');
    const id=ctx.member.id;
    await this.db.batch([
      query(this.db,'UPDATE members SET revoked_before=max(revoked_before,?1),updated_at=?1,version=version+1 WHERE id=?2',this.now,id),
      query(this.db,'UPDATE member_sessions SET revoked_at=? WHERE member_id=? AND revoked_at IS NULL AND expires_at>?',this.now,id,this.now),
      query(this.db,`INSERT INTO membership_audit VALUES (?,?,'revoke_all',?,?)`,crypto.randomUUID(),id,id,this.now),
    ]);
  }

  async accept(ctx: MembershipContext,body: Record<string,unknown>) {
    if (!ctx.identity.verifiedEmail) throw new HttpError(403,'email_unverified');
    const docs=body['documents'];
    if (body['version']!==policyVersion||!Array.isArray(docs)||docs.length!==policyDocuments.length||
        !policyDocuments.every(({kind})=>docs.includes(kind))) throw new HttpError(409,'policy_changed');
    const db=this.db;
    await db.batch([
      ...policyDocuments.map(({kind})=>query(db,`INSERT INTO policy_acceptances
        SELECT m.id,?1,?2,?3 FROM members m
        WHERE m.id=?4 AND m.state IN ('unverified','terms_required','active')
          AND EXISTS(SELECT 1 FROM member_sessions s WHERE s.id=?5 AND s.revoked_at IS NULL AND s.expires_at>?3 AND s.firebase_auth_at>=m.revoked_before)
        ON CONFLICT(member_id,kind,version) DO NOTHING`,kind,policyVersion,this.now,ctx.member.id,ctx.session.id)),
      query(db,`UPDATE members SET state='active',updated_at=?1,version=version+1
        WHERE id=?2 AND state IN ('unverified','terms_required') AND
          (SELECT count(*) FROM policy_acceptances WHERE member_id=?2 AND version=?3)=3`,this.now,ctx.member.id,policyVersion),
      query(db,`INSERT INTO membership_audit SELECT ?1,?2,'policies',?2,?3 WHERE changes()=1`,
        crypto.randomUUID(),ctx.member.id,this.now),
    ]);
  }

  async edit(ctx: MembershipContext,body: Record<string,unknown>,version: number) {
    if (ctx.phase!=='active'&&ctx.phase!=='profile_required') throw new HttpError(403,'access_denied');
    const nickname=inputText(body['nickname'],1,32);
    if (reservedNickname.test(nickname.normalize('NFKC'))) throw new HttpError(400,'nickname_reserved');
    const biography=inputText(body['biography']??'',0,500);
    const month=body['birthMonth']??null;
    const date=body['birthDay']??null;
    const publicCollection=body['collectionPublic']??false;
    const avatar=body['avatarMediaId']??null;
    const days=[31,29,31,30,31,30,31,31,30,31,30,31];
    if (typeof publicCollection!=='boolean'||!(month===null&&date===null||
        typeof month==='number'&&Number.isInteger(month)&&month>=1&&month<=12&&typeof date==='number'&&
        Number.isInteger(date)&&date>=1&&date<=(days[month-1]??0))||
        avatar!==null&&(typeof avatar!=='string'||!isId(avatar))) throw new HttpError(400,'invalid_request');
    const db=this.db;
    const rows=await db.batch([
      query(db,`UPDATE member_profiles SET nickname=?1,biography=?2,birth_month=?3,birth_day=?4,
        collection_public=?5,avatar_media_id=?6,configured_at=coalesce(configured_at,?7),updated_at=?7,version=version+1
        WHERE member_id=?8 AND version=?9 AND
        (?6 IS NULL OR EXISTS(SELECT 1 FROM media_reservations WHERE id=?6 AND owner_id=?8 AND state IN ('approved','attached') AND mime LIKE 'image/%'))
        AND EXISTS(SELECT 1 FROM member_sessions s JOIN members m ON m.id=s.member_id
          WHERE s.id=?10 AND m.id=?8 AND m.state='active' AND s.expires_at>?7
            AND s.revoked_at IS NULL AND s.firebase_auth_at>=m.revoked_before)`,
        nickname,biography,month as number|null,date as number|null,publicCollection?1:0,avatar as string|null,
        this.now,ctx.member.id,version,ctx.session.id),
      query(db,`INSERT INTO membership_audit SELECT ?1,?2,'profile',?2,?3 WHERE changes()=1`,
        crypto.randomUUID(),ctx.member.id,this.now),
    ]);
    if (rows[0]?.meta.changes!==1) throw new HttpError(409,'conflict');
  }
}

export type MembershipContext=Awaited<ReturnType<MembershipStore['context']>>;

export function officialOnly(ctx: MembershipContext) {
  if (ctx.phase!=='active'||ctx.member.role!=='artist') throw new HttpError(403,'access_denied');
}

export function staffOnly(ctx: MembershipContext,stepUpVerified=false) {
  if (ctx.phase!=='active'||ctx.member.role!=='administrator'||!stepUpVerified) throw new HttpError(403,'access_denied');
}

export async function beginDeletion(db: Database,ctx: MembershipContext,now: number) {
  if (now-ctx.identity.authAt>recent) throw new HttpError(401,'recent_auth_required');
  const member=ctx.member.id;
  await db.batch([
    query(db,`UPDATE members SET state='deleting',revoked_before=max(revoked_before,?1),updated_at=?1,version=version+1
      WHERE id=?2 AND state='active'`,now,member),
    query(db,`INSERT INTO deletion_requests SELECT ?1,id,'requested',?2,?2 FROM members
      WHERE id=?3 AND state='deleting' ON CONFLICT(member_id) DO NOTHING`,crypto.randomUUID(),now,member),
    query(db,`UPDATE member_sessions SET revoked_at=? WHERE member_id=? AND revoked_at IS NULL`,now,member),
    query(db,`INSERT INTO membership_audit VALUES (?,?,'deletion_begin',?,?)`,crypto.randomUUID(),member,member,now),
    enqueue(db,'member_deletion','deletion:'+member,{memberId:member},now,{required:true}),
  ]);
}
