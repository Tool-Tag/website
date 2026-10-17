import {createCipheriv,createDecipheriv,randomBytes} from "node:crypto";
export type LostPaymentDetails={method:string;holder:string;routing?:string;account?:string;handle?:string;address?:string};
function key(){const raw=process.env.TOOLTAG_PAYMENT_DETAILS_ENCRYPTION_KEY??"";const bytes=Buffer.from(raw,"base64");if(bytes.length!==32)throw new Error("Secure payment details are not configured. Please contact ToolTag.");return bytes;}
export function validateLostPaymentDetails(input:LostPaymentDetails,original:string):LostPaymentDetails{
 const {method}=input;const holder=(input.holder??"").trim();
 if(!["Zelle","Venmo","Bank Transfer","Card","Check"].includes(method)||(["Zelle","Venmo","Bank Transfer","Card"].includes(original)&&method!==original)||(method==="Card"&&original!=="Card"))throw new Error("Use your original electronic payment method.");
 if(holder.length<2||holder.length>150)throw new Error("Enter the account holder's name.");
 const result:LostPaymentDetails={method,holder};
 if(method==="Bank Transfer"){
  const routing=(input.routing??"").trim(),account=(input.account??"").trim();
  if(!/^\d{9}$/.test(routing)||!/^\d{4,17}$/.test(account)||Number(routing)===0||[3,7,1,3,7,1,3,7,1].reduce((sum,w,i)=>sum+w*Number(routing[i]),0)%10!==0)throw new Error("Enter a valid routing number and account number.");
  result.routing=routing;result.account=account;
 }else if(method==="Zelle"||method==="Venmo"){
  const handle=(input.handle??"").trim();if(handle.length<3||handle.length>200||(method==="Zelle"&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(handle)&&!/^\+?[0-9 ()-]{10,20}$/.test(handle))||(method==="Venmo"&&!/^@?[A-Za-z0-9_-]{3,30}$/.test(handle)))throw new Error("Enter your payment email, phone or handle.");result.handle=handle;
 }else if(method==="Check"){
  const address=(input.address??"").trim();if(address.length<5||address.length>500)throw new Error("Enter your complete mailing address.");result.address=address;
 }
 return result;
}
export function encryptLostPaymentDetails(details:LostPaymentDetails,lostId:string){const iv=randomBytes(12),cipher=createCipheriv("aes-256-gcm",key(),iv);cipher.setAAD(Buffer.from(lostId));const encrypted=Buffer.concat([cipher.update(JSON.stringify(details),"utf8"),cipher.final()]);return ["v1",iv.toString("base64url"),cipher.getAuthTag().toString("base64url"),encrypted.toString("base64url")].join(".");}
export function decryptLostPaymentDetails(value:string,lostId:string):LostPaymentDetails{const [version,iv,tag,data]=value.split(".");if(version!=="v1")throw new Error("Unsupported payment details format");const cipher=createDecipheriv("aes-256-gcm",key(),Buffer.from(iv,"base64url"));cipher.setAAD(Buffer.from(lostId));cipher.setAuthTag(Buffer.from(tag,"base64url"));return JSON.parse(Buffer.concat([cipher.update(Buffer.from(data,"base64url")),cipher.final()]).toString("utf8"));}
