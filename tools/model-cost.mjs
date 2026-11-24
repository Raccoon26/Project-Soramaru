
import { metricDefinitions } from '../services/api/src/cost.ts';

export const scenarios = {
  ordinary: [.30,20,10,70,1],
  officialAudio: [.70,27,65,90,1.1],
  officialPhoto: [.72,32,10,250,1.5],
  massNotice: [.70,37,12,86,1.2],
  registrations: [.55,42,8,38,2.5],
  rangeSpike: [.60,23,120,85,1.1],
  repeatDownload: [.65,34,100,160,1.4],
  retryStorm: [.65,55,70,155,1.6],
  abuse: [.50,85,28,105,1.3],
};

function day(mau,scenario) {
  const [active,appCalls,audio,image,mutation] = scenarios[scenario];
  const dau = Math.ceil(mau*Math.round(active*100)/100);
  const gated = appCalls*dau;
  const requests = 800+gated+(scenario==='abuse'?2000+20*dau:0);
  return {
    dau, peakConcurrent: Math.ceil(dau*.18*8/60), requests,
    d1Reads: 9_000 + gated*37,
    // Shared budget row + four indexed rate scopes on every gated call;
    // extra domain/index writes and background work are separate here.
    d1Writes: 1_500 + gated*9 + Math.ceil(dau*6*Math.round(mutation*10)/10),
    r2A: 45 + Math.ceil(dau*2*Math.round(mutation*10)/100),
    r2B: 200+Math.ceil(dau*(audio+image)),
  };
}

export function storage(mau,months) {
  const memberPhotos = .32*mau*months;
  const officialMonthly = 4*10*.72+30*(20/60)*.72+2*30*.72+40*.42;
  const official = officialMonthly*months;
  const d1 = 30+(1.5+.003*mau)*months;
  const backup = 2*(d1 + .32*mau + officialMonthly);
  const quarantine = (mau*.1+32);
  const peakGB = (300 + memberPhotos + official + backup + quarantine)/1000;
  return { peakGB, d1, memberPhotos,official,backup,quarantine };
}

export function model(mau,scenario,months=1) {
  const ordinary = day(mau,'ordinary');
  const peak = day(mau,scenario);
  const capacity = storage(mau,months);
  const r2A = 29*ordinary.r2A+peak.r2A;
  const r2B = 29*ordinary.r2B+peak.r2B;
  const excess = (value,unit,free) => Math.max(0,Math.ceil(value/unit)-free);
  const usd = excess(capacity.peakGB,1,10)*.015 + excess(r2A,1_000_000,1)*4.5 +
    excess(r2B,1_000_000,10)*.36;
  const ratio = Math.max(...Object.entries({
    requests:peak.requests,d1Reads:peak.d1Reads,d1Writes:peak.d1Writes,
    d1DatabaseBytes:capacity.d1*1_000_000,r2A,r2B,r2StoredBytes:capacity.peakGB*1_000_000_000,
  }).map(([name,value]) => value/metricDefinitions[name][1]));
  return { mau,scenario,...peak,...capacity,r2A,r2B,ratio,usd,jpy:Math.ceil(160*usd) };
}

const names = {
  ordinary:'일반',officialAudio:'음성 공개',officialPhoto:'사진 공개',massNotice:'대량 알림',
  registrations:'신규 가입 집중',rangeSpike:'Range 증가',repeatDownload:'반복 다운로드',
  retryStorm:'재시도 집중',abuse:'악용 집중',
};
const sizes = [100,500,1000,5000];
export function render() {
  const lines = [
    '| MAU | 부하 | DAU / 동시 | Worker 요청·일 | D1 읽기·일 | D1 쓰기·일 | R2 A·월 | R2 B·월 | 최대 무료량 비율 |',
    '|---:|---|---:|---:|---:|---:|---:|---:|---:|',
  ];
  for (const mau of sizes) {
    for (const scenario of Object.keys(scenarios)) {
      const r=model(mau,scenario);
      lines.push('| '+[mau,names[scenario],r.dau+' / '+r.peakConcurrent,r.requests,r.d1Reads,
        r.d1Writes,r.r2A,r.r2B,Math.round(r.ratio*100)+'%'].join(' | ')+' |');
    }
  }
  lines.push('', '| MAU | 1개월 GB | 6개월 GB | 12개월 GB | 24개월 GB | 36개월 GB | 36개월 D1 MB | 36개월 R2 엔/월 예시 |',
    '|---:|---:|---:|---:|---:|---:|---:|---:|');
  for (const mau of sizes) {
    const r=model(mau,'ordinary',36);
    lines.push('| '+[mau,...[1,6,12,24,36].map(t=>storage(mau,t).peakGB.toFixed(2)),r.d1.toFixed(1),r.jpy].join(' | ')+' |');
  }
  return lines.join('\n');
}
