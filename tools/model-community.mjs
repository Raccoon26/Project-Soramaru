import process from 'node:process';
import { pathToFileURL } from 'node:url';

// Average per active member, measured fixture rounded up for modeling.
const cost={
  first:[110,3],next:[100,3],detail:[45,3],create:[160,60],
  edit:[170,70],remove:[140,38],report:[130,18],block:[115,15],
};
const normal=[3,2,3,.12,.04,.02,.025,.015];
const cases={
  ordinary:[.30,normal],
  announcement:[.72,[8,4,7,.32,.12,.05,.06,.04]],
  registrations:[.55,[6,3,4,.34,.08,.03,.04,.04]],
  posting:[.60,[5,4,6,1,.30,.12,.04,.04]],
  reporting:[.55,[5,3,6,.15,.05,.03,.45,.15]],
  refresh:[.68,[18,5,5,.14,.04,.02,.03,.03]],
  scrolling:[.65,[6,18,9,.15,.04,.03,.03,.04]],
};

export function communityCost(mau,scenario) {
  const [active,counts]=cases[scenario];
  const dau=Math.ceil(mau*Math.round(active*100)/100);
  const keys=Object.keys(cost);
  const calls=Object.fromEntries(keys.map((name,index)=>[name,Math.ceil(dau*counts[index])]));
  const delta=Object.entries(calls).reduce((total,[name,count])=>({
    requests:total.requests+count,
    read:total.read+count*cost[name][0],
    write:total.write+count*cost[name][1],
  }),{requests:0,read:0,write:0});
  // Keep a DEV-04 background estimate, scaled on peak active usage.
  const baseWrites=1500+78*dau;
  const baseReads=9000+dau*20*37;
  return {mau,scenario,dau,calls,...delta,totalWrites:baseWrites+delta.write,totalReads:baseReads+delta.read};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  for(const mau of [100,500,1000,5000])for(const scenario of Object.keys(cases)){
    const row=communityCost(mau,scenario);
    globalThis.console.log([row.mau,row.scenario,row.dau,row.requests,row.totalReads,row.totalWrites].join(' | '));
  }
}
