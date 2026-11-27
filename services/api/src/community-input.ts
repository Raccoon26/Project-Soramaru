import { graphemeSegments } from 'unicode-segmenter/grapheme';
import { HttpError } from './http.ts';
import { isId } from './platform.ts';

export const postBodyBytes=360_000;
export const postRequestBytes=730_000;
const encoder=new TextEncoder();
// eslint-disable-next-line no-control-regex
export const banned=/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]|[\ud800-\udfff]/u;

export function tagValue(value: unknown) {
  if (typeof value!=='string'||banned.test(value)) throw new HttpError(400,'invalid_request');
  const label=value.trim().replace(/^[#＃]/u,'');
  const normalized=label.normalize('NFKC').toLowerCase();
  const allowed=/^[\p{L}\p{M}\p{N}_-]{1,48}$/u;
  if (!allowed.test(normalized)||![...normalized].some(c=>/[\p{L}\p{N}]/u.test(c))||[...label].length>48) {
    throw new HttpError(400,'invalid_request');
  }
  return {label,normalized};
}

export function moderate(text: string) {
  const scan=text.normalize('NFKC');
  if (banned.test(text)||/<\/?[a-z][^<>\n]*>/iu.test(scan)||
      /\b(?:javascript|vbscript|data|file)\s*:/i.test(scan)||
      /[\w.+-]+@[\w.-]+\.[a-z]{2,}/i.test(scan)||
      /(?:\+81[- ]?|0)(?:[5789]0)[- ]\d{4}[- ]\d{4}/u.test(scan)||
      (scan.match(/https?:\/\//gi)?.length??0)>3) {
    throw new HttpError(400,'content_rejected');
  }
}

export function postInput(value: Record<string,unknown>, edit: boolean) {
  if (Object.keys(value).some(k=>!['body','tags','attachments',...(edit?[]:['quoteId','quoteAlbumId'])].includes(k))||
      typeof value.body!=='string'||!Array.isArray(value.tags)||value.tags.length>10) {
    throw new HttpError(400,'invalid_request');
  }
  const body=value.body.replace(/\r\n?/g,'\n');
  const quoteId=value.quoteId??null;
  if (quoteId!==null&&(typeof quoteId!=='string'||!isId(quoteId))) throw new HttpError(400,'invalid_request');
  const quoteAlbumId=value.quoteAlbumId??null;
  if (quoteAlbumId!==null&&(quoteId!==null||typeof quoteAlbumId!=='string'||!isId(quoteAlbumId))) throw new HttpError(400,'invalid_request');
  const attachments=value.attachments??null;
  if(attachments!==null&&(!Array.isArray(attachments)||attachments.length>10||
      !attachments.every((v:unknown)=>typeof v==='string'&&isId(v))||new Set(attachments).size!==attachments.length)) {
    throw new HttpError(400,'invalid_request');
  }
  if ((!body.trim()&&!edit&&quoteId===null&&quoteAlbumId===null&&(!attachments||attachments.length===0))||encoder.encode(body).length>postBodyBytes) {
    throw new HttpError(body.trim()?413:400,body.trim()?'payload_too_large':'invalid_request');
  }
  let size=0;
  for (const {segment} of graphemeSegments(body)) {
    if (++size>10_000||[...segment].length>64) throw new HttpError(400,'invalid_post_length');
  }
  const tags=[...new Map(value.tags.map(tag=>tagValue(tag)).map(tag=>[tag.normalized,tag])).values()];
  moderate(body);
  return {body,tags,quoteId,quoteAlbumId,attachments:attachments as string[]|null};
}
