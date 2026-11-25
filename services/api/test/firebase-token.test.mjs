import assert from 'node:assert/strict';
import { test } from 'node:test';
import { base64url,productionVerifier,googleKeys,demoProject } from '../src/firebase.ts';

const subtle=globalThis.crypto.subtle;
const encoder=new globalThis.TextEncoder();
const now=Date.UTC(2026,10,25,0);
const project='fixture-membership';
const second=now/1000;
const uid='synthetic-subject';
const base={aud:project,iss:'https://securetoken.google.com/'+project,sub:uid,
  email_verified:true,auth_time:second-60,iat:second-30,exp:second+600};

const keys=()=>subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,
  publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);

async function jwt(key,claims=base,header={alg:'RS256',kid:'known-fixture'}) {
  const encode=value=>base64url(encoder.encode(JSON.stringify(value)));
  const data=encode(header)+'.'+encode(claims);
  return data+'.'+(key?base64url(new Uint8Array(await subtle.sign('RSASSA-PKCS1-v1_5',key,encoder.encode(data)))):'');
}

test('production verifier accepts only Firebase issuer, audience, RS256 and current signed claims',async()=>{
  const signer=await keys(), other=await keys();
  const verify=productionVerifier(project,async kid=>kid==='known-fixture'?signer.publicKey:null,
    async()=>({uid,emailVerified:true,disabled:false,validSince:0}));
  const signed=await jwt(signer.privateKey);
  assert.equal((await verify(signed,now)).uid,uid);
  assert.equal(await verify(await jwt(other.privateKey),now),null);
  assert.equal(await verify(await jwt(null,base,{alg:'none',kid:'known-fixture'}),now),null);
  assert.equal(await verify(await jwt(signer.privateKey,base,{alg:'HS256',kid:'known-fixture'}),now),null);
  for(const claims of [
    {...base,aud:'other-firebase'}, {...base,iss:'https://example.invalid'},
    {...base,iat:second+1},{...base,exp:second},{...base,auth_time:second+1},
    {...base,auth_time:base.iat+1},{...base,sub:''},{...base,user_id:'mismatch'},
    {...base,email_verified:'true'},
  ]) assert.equal(await verify(await jwt(signer.privateKey,claims),now),null);
  assert.equal(await verify(await jwt(signer.privateKey,base,{alg:'RS256',kid:'missing'}),now),null);
  assert.equal(await verify(await jwt(signer.privateKey,base,{alg:'RS256',kid:'known-fixture',jku:'https://example.invalid'}),now),null);
  assert.throws(()=>productionVerifier(demoProject,async()=>null,async()=>null),/not configured/);
});

test('signed token still requires trusted current account and revocation status',async()=>{
  const signer=await keys();
  const token=await jwt(signer.privateKey);
  for(const current of [
    null,{uid:'different',emailVerified:true,disabled:false,validSince:0},
    {uid,emailVerified:true,disabled:true,validSince:0},
    {uid,emailVerified:true,disabled:false,validSince:now-15_000},
  ]) {
    const verify=productionVerifier(project,async()=>signer.publicKey,async()=>current);
    assert.equal(await verify(token,now),null);
  }
  const unverified=productionVerifier(project,async()=>signer.publicKey,
    async()=>({uid,emailVerified:false,disabled:false,validSince:0}));
  assert.equal((await unverified(token,now)).verifiedEmail,false);
});

test('fixed JWKS endpoint rotates keys with expiry, limited unknown-kid loads and fail-closed outage',async()=>{
  const a=await keys(), b=await keys();
  const jwk=async(key,kid)=>({...await subtle.exportKey('jwk',key),kid,use:'sig',alg:'RS256'});
  const initial=await jwk(a.publicKey,'initial'), rotated=await jwk(b.publicKey,'rotated');
  let calls=0;
  const source=googleKeys(async(url,init)=>{
    assert.equal(url,'https://www.googleapis.com/service_accounts/v1/jwk/securetoken%40system.gserviceaccount.com');
    assert.equal(init.redirect,'manual');
    calls++;
    return calls===3?new globalThis.Response('',{status:503}):
      globalThis.Response.json({keys:[calls===1?initial:rotated]},{headers:{'cache-control':'max-age=60'}});
  });
  assert.ok(await source('initial',now));
  assert.equal(await source('rotated',now+1000),null);
  assert.ok(await source('rotated',now+60_000));
  assert.equal(await source('initial',now+60_010),null);
  assert.equal(await source('rotated',now+120_000),null);
  assert.equal(calls,3);
});
