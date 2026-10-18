export const HEIC_ACCEPT="image/heic,image/heif,image/heic-sequence,image/heif-sequence,.heic,.heif";
export const PHOTO_ACCEPT=`image/png,image/jpeg,image/webp,${HEIC_ACCEPT}`;
export function photoAccept(accept?:string){return accept?.includes("image/")?`${accept},${HEIC_ACCEPT}`:accept;}
type Decoder=(blob:Blob)=>Promise<Blob|Blob[]>;
async function decode(blob:Blob){const {default:heic2any}=await import("heic2any");return heic2any({blob,toType:"image/jpeg",quality:0.85});}
export async function isHeic(file:File){
 if(/\.(heic|heif)$/i.test(file.name)||/^image\/hei[cf](?:-sequence)?$/i.test(file.type))return true;
 const header=new Uint8Array(await file.slice(0,40).arrayBuffer());
 const text=String.fromCharCode(...header);
 return text.slice(4,8)==="ftyp"&&/(heic|heix|hevc|hevx|heim|heis|hevm|hevs|mif1|msf1)/.test(text.slice(8));
}
/** Decode first. Each uploader applies its existing size/type limit to the JPEG result. */
export async function normalizePhoto(file:File,decoder:Decoder=decode):Promise<File>{
 if(!(await isHeic(file)))return file;
 try{
  const result=await decoder(file),blob=Array.isArray(result)?result[0]:result;
  if(!blob||!blob.size||blob.type!=="image/jpeg")throw new Error("Invalid JPEG");
  return new File([blob],file.name.replace(/\.[^.]+$/,"")+".jpg",{type:"image/jpeg",lastModified:file.lastModified});
 }catch{throw new Error("This HEIC/HEIF photo could not be converted. Please choose another photo or export it as JPEG.");}
}
