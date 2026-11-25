export interface FirebaseIdentity {
  uid: string;
  verifiedEmail: boolean;
  authAt: number;
  validSince?: number;
}
export interface ProviderStatus {
  uid: string;
  emailVerified: boolean;
  disabled: boolean;
  validSince: number;
}
export type ProviderLookup = (token: string) => Promise<ProviderStatus | null>;
export type FirebaseVerifier = (token: string, now: number) => Promise<FirebaseIdentity | null>;
export type KeySource = (kid: string, now: number) => Promise<CryptoKey | null>;

interface Parsed {
  header: Record<string, unknown>;
  claims: Record<string, unknown>;
  data: Uint8Array<ArrayBuffer>;
  signature: Uint8Array<ArrayBuffer>;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8',{fatal:true});
const publicKeys = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken%40system.gserviceaccount.com';

export function base64url(data: Uint8Array): string {
  return btoa(String.fromCharCode(...data)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
}

function bytes(encoded: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) throw new Error('JWT encoding');
  const value = Uint8Array.from(atob(encoded.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
  if (base64url(value)!==encoded) throw new Error('JWT encoding');
  return value;
}

function object(encoded: string): Record<string, unknown> {
  const value: unknown = JSON.parse(decoder.decode(bytes(encoded)));
  if (typeof value!=='object'||value===null||Array.isArray(value)) throw new Error('JWT object');
  return value as Record<string,unknown>;
}

function parse(token: string, allowUnsigned: boolean): Parsed {
  const [h,p,s,extra] = token.split('.');
  if (token.length>8192||!h||!p||s===undefined||extra!==undefined||!s&&!allowUnsigned) throw new Error('JWT syntax');
  const header=object(h);
  if (['jku','x5u','jwk','crit'].some(key=>Object.hasOwn(header,key))) throw new Error('JWT header');
  return {header,claims:object(p),data:encoder.encode(h+'.'+p),signature:s?bytes(s):new Uint8Array()};
}

function claimsFor(claims: Record<string,unknown>, project: string, now: number) {
  const {aud,iss,sub,iat,exp,auth_time,email_verified,user_id}=claims;
  const seconds=Math.floor(now/1000);
  if (aud!==project||iss!=='https://securetoken.google.com/'+project||
      typeof sub!=='string'||sub.length<1||sub.length>128||user_id!==undefined&&user_id!==sub||
      typeof iat!=='number'||!Number.isSafeInteger(iat)||iat<1||iat>seconds||
      typeof exp!=='number'||!Number.isSafeInteger(exp)||exp<=seconds||exp-iat>3660||
      typeof auth_time!=='number'||!Number.isSafeInteger(auth_time)||auth_time<1||auth_time>iat||
      typeof email_verified!=='boolean') throw new Error('JWT claims');
  return {uid:sub,verifiedEmail:email_verified,authAt:auth_time*1000};
}

async function confirmed(token: string, identity: FirebaseIdentity, status: ProviderLookup) {
  const current=await status(token);
  if (!current||current.uid!==identity.uid||current.disabled||!Number.isSafeInteger(current.validSince)||
      current.validSince<0||identity.authAt<current.validSince) return null;
  return {...identity,verifiedEmail:identity.verifiedEmail&&current.emailVerified,validSince:current.validSince};
}

export function productionVerifier(project: string, keys: KeySource, status: ProviderLookup): FirebaseVerifier {
  if (!/^[a-z][a-z0-9-]{4,29}$/.test(project)||project.startsWith('demo-')) throw new Error('Production project not configured');
  return async (token,now) => {
    let identity: FirebaseIdentity;
    try {
      const jwt=parse(token,false);
      const kid=jwt.header['kid'];
      if (jwt.header['alg']!=='RS256'||typeof kid!=='string'||!/^[A-Za-z0-9_-]{1,100}$/.test(kid)) return null;
      identity=claimsFor(jwt.claims,project,now);
      const key=await keys(kid,now);
      if (!key||key.algorithm.name!=='RSASSA-PKCS1-v1_5'||
          !await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key,jwt.signature,jwt.data)) return null;
    } catch {
      return null;
    }
    return confirmed(token,identity,status);
  };
}

export const demoProject='demo-soramaru-auth';

export function emulatorVerifier(status: ProviderLookup): FirebaseVerifier {
  return async (token,now) => {
    let identity: FirebaseIdentity;
    try {
      const jwt=parse(token,true);
      if (jwt.header['alg']!=='none'||jwt.signature.length!==0) return null;
      identity=claimsFor(jwt.claims,demoProject,now);
    } catch {
      return null;
    }
    return confirmed(token,identity,status);
  };
}

interface RemoteKey extends JsonWebKey { kid?: string; alg?: string }

export function googleKeys(fetcher: typeof fetch = fetch): KeySource {
  let active=new Map<string,CryptoKey>();
  let expires=0;
  let lastAttempt=-60_000;
  let refreshing: Promise<void>|undefined;

  async function refresh(now: number) {
    lastAttempt=now;
    const response=await fetcher(publicKeys,{redirect:'manual',signal:AbortSignal.timeout(4000)});
    if (!response.ok) throw new Error('Firebase keys unavailable');
    const body=await response.json() as {keys?: RemoteKey[]};
    if (!Array.isArray(body.keys)||body.keys.length<1||body.keys.length>20) throw new Error('Firebase key set');
    const keys=new Map<string,CryptoKey>();
    for (const jwk of body.keys) {
      if (jwk.kty!=='RSA'||jwk.use!=='sig'||jwk.alg&&jwk.alg!=='RS256'||
          typeof jwk.kid!=='string'||!jwk.n||!jwk.e||bytes(jwk.n).byteLength<256) continue;
      keys.set(jwk.kid,await crypto.subtle.importKey('jwk',jwk,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['verify']));
    }
    if (!keys.size) throw new Error('No Firebase keys');
    const maxAge=Number(/(?:^|,)\s*max-age=(\d+)/i.exec(response.headers.get('cache-control')||'')?.[1]??'0');
    active=keys;
    expires=now+Math.min(maxAge,21_600)*1000;
  }

  return async (kid,now) => {
    if (now<expires&&active.has(kid)) return active.get(kid)??null;
    if (!refreshing&&now-lastAttempt>=60_000) {
      refreshing=refresh(now).catch(()=>undefined).finally(()=>{refreshing=undefined;});
    }
    await refreshing;
    return now<expires?active.get(kid)??null:null;
  };
}

export function productionFirebase(project:string,apiKey:string,fetcher:typeof fetch=fetch):FirebaseVerifier {
  if (!/^[A-Za-z0-9_-]{20,100}$/.test(apiKey)) throw new Error('Firebase API key not configured');
  const endpoint=new URL('https://identitytoolkit.googleapis.com/v1/accounts:lookup');
  endpoint.searchParams.set('key',apiKey);
  return productionVerifier(project,googleKeys(fetcher),async idToken=>{
    const result=await fetcher(endpoint,{
      method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({idToken}),
      redirect:'manual',signal:AbortSignal.timeout(4000),
    });
    if (result.status===400||result.status===401||result.status===403) return null;
    if (!result.ok) throw new Error('Firebase account status unavailable');
    const data=await result.json() as {users?:{localId?:string;emailVerified?:boolean;disabled?:boolean;validSince?:string}[]};
    const user=data.users?.length===1?data.users[0]:undefined;
    if (!user?.localId||typeof user.validSince!=='string'||!/^\d{1,12}$/.test(user.validSince)) return null;
    return {uid:user.localId,emailVerified:user.emailVerified===true,disabled:user.disabled===true,validSince:Number(user.validSince)*1000};
  });
}
