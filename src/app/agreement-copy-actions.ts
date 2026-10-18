"use server";
import {after} from "next/server";
import {supabase} from "@/lib/supabase/server";
import {mailEnabled} from "@/lib/integrations/gmail";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
export async function resendAgreementDocument(token:string,document:string,request:string):Promise<{error?:string;ok?:boolean}>{
 if(!/^[a-f0-9]{64}$/i.test(token)||![document,request].every(v=>/^[a-f0-9-]{36}$/i.test(v)))return {error:"Invalid document link."};
 if(!mailEnabled()||process.env.TOOLTAG_MAIL_MODE!=="live")return {error:"Agreement email delivery is not enabled in this environment."};
 try{const db=await supabase();const {error}=await db.rpc("request_agreement_document_copy",{p_token:token,p_document:document,p_request:request});if(error)return {error:error.message};after(()=>dispatchWorkerMail());return {ok:true};}
 catch{return {error:"Unable to request your agreement copy. Please try again or contact ToolTag."};}
}
