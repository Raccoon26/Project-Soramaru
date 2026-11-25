import worker,{createApi} from './index.ts';
import { demoProject,emulatorVerifier } from './firebase.ts';
import type { ProviderStatus } from './firebase.ts';
import type { Env } from './platform.ts';

interface LocalBindings extends Env { AUTH_SESSION_KEY?: string }

const loopback='http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:';

async function firebase(action:string,body:object) {
  return fetch(loopback+action+'?key=demo-local-key',{
    method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),
    redirect:'manual',signal:AbortSignal.timeout(4500),
  });
}

const verify=emulatorVerifier(async token => {
  const result=await firebase('lookup',{idToken:token});
  if (!result.ok) return null;
  const data=await result.json() as {users?: {localId?:string;emailVerified?:boolean;disabled?:boolean;validSince?:string}[]};
  const user=data.users?.[0];
  if (!user?.localId) return null;
  return {
    uid:user.localId,emailVerified:user.emailVerified===true,disabled:user.disabled===true,
    validSince:user.validSince===undefined?0:Number(user.validSince)*1000,
  } satisfies ProviderStatus;
});

let provisioned: { value:string; api: ReturnType<typeof createApi> }|undefined;

export default {
  ...worker,
  async fetch(request:Request,env:LocalBindings) {
    const secret=env?.AUTH_SESSION_KEY;
    if ((env?.APP_ENV!=='local'&&env?.APP_ENV!=='test')||!secret||!/^[0-9a-f]{64}$/.test(secret)) {
      return worker.fetch(request,env);
    }
    if (!provisioned||provisioned.value!==secret) {
      const bytes=Uint8Array.from(secret.match(/../g)??[],x=>Number.parseInt(x,16));
      const key=await crypto.subtle.importKey('raw',bytes,{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
      provisioned={value:secret,api:createApi({membership:{verify,key,async sendCode(kind,value) {
        const result=await firebase('sendOobCode',{
          requestType:kind==='verify'?'VERIFY_EMAIL':'PASSWORD_RESET',
          ...(kind==='verify'?{idToken:value}:{email:value}),
        });
        if (result.status>=500) throw new Error('Emulator mail unavailable');
        // Always acknowledge reset requests identically. The backend owns
        // the quota and never places provider error details in responses.
      }}})};
    }
    return provisioned.api(request,env);
  },
};

export {demoProject};
