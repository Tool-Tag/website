import {paymentProofError} from "../payments/proof";
export function expenseProofError(file:{size:number;type:string},bytes?:Uint8Array) {
  if(file.size<=0||paymentProofError(file))return "Use a PNG, JPG or WebP receipt image up to 3.5 MB.";
  if(bytes){
    const png=bytes.length>=8&&[137,80,78,71,13,10,26,10].every((b,i)=>bytes[i]===b);
    const jpg=bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255;
    const webp=bytes.length>=12&&String.fromCharCode(...bytes.slice(0,4))==="RIFF"&&String.fromCharCode(...bytes.slice(8,12))==="WEBP";
    if(!((file.type==="image/png"&&png)||(file.type==="image/jpeg"&&jpg)||(file.type==="image/webp"&&webp)))return "The receipt must be a valid PNG, JPG or WebP image.";
  }
  return null;
}
