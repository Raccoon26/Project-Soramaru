import process from 'node:process';
import { spawn } from 'node:child_process';
import { mkdir,readFile,writeFile } from 'node:fs/promises';
import { URL,fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { demoProject } from '../services/api/src/firebase.ts';

const repository=new URL('../',import.meta.url);
const dir=new URL('.local/firebase/',repository);
const target='http://127.0.0.1:9099/emulator/v1/projects/'+demoProject+'/accounts';
const mode=process.argv[2]??'start';
const version='15.37.0';

function launch(script,args,options={}) {
  return spawn(process.execPath,[fileURLToPath(new URL(script,repository)),...args],options);
}

async function reachable() {
  try {
    return (await globalThis.fetch(target.replace('/accounts','/oobCodes'),{signal:globalThis.AbortSignal.timeout(600)})).ok;
  } catch {
    return false;
  }
}

async function scopedSessionKey() {
  const file=new URL('session.key',dir);
  const generate=()=>globalThis.Buffer.from(globalThis.crypto.getRandomValues(new Uint8Array(32))).toString('hex');
  try {
    await writeFile(file,generate(),{flag:'wx',mode:0o600});
  } catch (error) {
    if (error.code!=='EEXIST') throw error;
  }
  const value=(await readFile(file,'utf8')).trim();
  if (!/^[a-f0-9]{64}$/.test(value)) throw new Error('Invalid local session key file');
  return value;
}

if (mode==='worker') {
  await mkdir(dir,{recursive:true});
  const key=await scopedSessionKey();
  const child=launch('node_modules/vite/bin/vite.js',['dev','--host','127.0.0.1','--port','8787','--strictPort'],{
    cwd:fileURLToPath(new URL('services/api/',repository)),stdio:'inherit',
    env:{...process.env,SORAMARU_LOCAL_AUTH_KEY:key,SORAMARU_RUNTIME:'local',CLOUDFLARE_SEND_METRICS:'false'},
  });
  process.on('SIGINT',()=>child.kill('SIGINT'));
  process.on('SIGTERM',()=>child.kill('SIGTERM'));
  process.exitCode=await new Promise((resolve,reject)=>{
    child.once('error',reject);
    child.once('exit',code=>resolve(code??0));
  });
} else {
  if (!['start','test'].includes(mode)) throw new Error('Choose start, test or worker');
  if (await reachable()) throw new Error('The Firebase Auth localhost port is already in use');
  await mkdir(dir,{recursive:true});
  const child=launch('.local/sdk/firebase/node_modules/firebase-tools/lib/bin/firebase.js',
    ['emulators:start','--only','auth','--project',demoProject,'--config',fileURLToPath(new URL('firebase.local.json',repository))],
    {cwd:fileURLToPath(dir),stdio:'ignore',env:{...process.env,CI:'true',FIREBASE_CLI_DISABLE_USAGE_REPORTING:'true',
      XDG_CONFIG_HOME:fileURLToPath(dir),FIREBASE_CLI_EXPERIMENTS:''}});
  const done=new Promise(resolve=>{
    child.once('error',()=>resolve(1));
    child.once('exit',code=>resolve(code??0));
  });
  let stopped=false;
  const stop=()=>{
    if (!stopped) {
      stopped=true;
      child.kill();
    }
  };
  process.on('SIGINT',stop);
  process.on('SIGTERM',stop);
  try {
    let ready=false;
    const deadline=Date.now()+90_000;
    while (Date.now()<deadline) {
      if (child.exitCode!==null||stopped) break;
      if (await reachable()) {ready=true;break;}
      await sleep(250);
    }
    if (!ready) throw new Error('Firebase Auth Emulator did not start; check the local CLI ('+version+') and ignored emulator logs');
    globalThis.console.log('Firebase Auth Emulator is ready on 127.0.0.1:9099 ('+demoProject+')');
    if (mode==='start') process.exitCode=await done;
    else {
      const tester=launch('services/api/test/firebase-integration.mjs',[],{
        cwd:fileURLToPath(repository),stdio:'inherit',env:{...process.env,FIREBASE_AUTH_EMULATOR_HOST:'127.0.0.1:9099'},
      });
      process.exitCode=await new Promise((resolve,reject)=>{
        tester.once('error',reject);
        tester.once('exit',code=>resolve(code??1));
      });
    }
  } finally {
    if (mode==='test') {
      await globalThis.fetch(target,{method:'DELETE',signal:globalThis.AbortSignal.timeout(1500)}).catch(()=>undefined);
    }
    stop();
    await done;
  }
}
