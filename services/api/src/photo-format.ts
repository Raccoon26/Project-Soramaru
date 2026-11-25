import { decode } from 'jpeg-js';

export type PhotoPurpose = 'post'|'thumbnail'|'avatar'|'gallery';
export const photoLimits = {post:[1920,800_000],thumbnail:[400,90_000],avatar:[512,150_000],gallery:[2048,800_000]} as const;

// The app emits single-scan, 8-bit baseline JPEG. Bound all reads and reject
// ancillary segments before the decoder sees the input. JFIF has no thumbnail.
export function jpegDimensions(source: ArrayBuffer, purpose: PhotoPurpose) {
  const bytes=new Uint8Array(source);
  const [length,capacity]=photoLimits[purpose];
  if(bytes.length<24||bytes.length>capacity||bytes[0]!==255||bytes[1]!==216) return null;
  let width=0,height=0,segments=0;
  let quant=false,huffman=false,jfif=false;
  for(let offset=2;offset+4<=bytes.length&&++segments<=32;){
    if(bytes[offset]!==255) return null;
    const marker=bytes[offset+1];
    const count=(bytes[offset+2]??0)*256+(bytes[offset+3]??0);
    const start=offset+4,end=offset+2+count;
    if(count<2||end>bytes.length) return null;
    if(marker===224) {
      if(jfif||offset!==2||count!==16||bytes[start]!==74||bytes[start+1]!==70||bytes[start+2]!==73||
          bytes[start+3]!==70||bytes[start+4]!==0||bytes[end-2]!==0||bytes[end-1]!==0) return null;
      jfif=true;
    } else if(marker===192) {
      if(width!==0||count!==17||bytes[start]!==8||bytes[start+5]!==3) return null;
      height=(bytes[start+1]??0)*256+(bytes[start+2]??0);
      width=(bytes[start+3]??0)*256+(bytes[start+4]??0);
      if(!width||!height||width>length||height>length||width*height>4_194_304) return null;
      if(purpose==='avatar'&&width!==height) return null;
      for(let index=0;index<3;index++) {
        const sampling=bytes[start+7+3*index]??0;
        if(![0x11,0x21,0x22,0x12].includes(sampling)) return null;
      }
    } else if(marker===219) {
      if(count<67||count>262||(count-2)%65!==0) return null;
      for(let table=start;table<end;table+=65) if((bytes[table]??255)>3) return null;
      quant=true;
    } else if(marker===196) {
      if(count<20||count>1100) return null;
      huffman=true;
    } else if(marker===218) {
      if(!width||!height||!quant||!huffman||count!==12||bytes[start]!==3||
          bytes[end-3]!==0||bytes[end-2]!==63||bytes[end-1]!==0) return null;
      // Exactly one scan and one terminal EOI. No extra payload or hidden scans.
      for(let scan=end;scan+1<bytes.length;scan++){
        if(bytes[scan]!==255) continue;
        const following=bytes[++scan];
        if(following===217&&scan===bytes.length-1&&scan>end+4) return {width,height};
        if(following!==0) return null;
      }
      return null;
    } else {
      return null;
    }
    offset=end;
  }
  return null;
}

export function inspectPhoto(source: ArrayBuffer,purpose: PhotoPurpose) {
  const expected=jpegDimensions(source,purpose);
  if(!expected) return false;
  try {
    const image=decode(new Uint8Array(source), {
      useTArray:true,formatAsRGBA:false,tolerantDecoding:false,maxResolutionInMP:4.2,maxMemoryUsageInMB:48,
    });
    return image.width===expected.width&&image.height===expected.height?expected:false;
  } catch {
    return false;
  }
}
