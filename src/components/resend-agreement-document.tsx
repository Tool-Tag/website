"use client";
import {useRef,useState,useTransition} from "react";
import {resendAgreementDocument} from "@/app/agreement-copy-actions";
export function ResendAgreementDocument({token,document}:{token:string;document:string}){
 const request=useRef<string|null>(null),[pending,start]=useTransition(),[error,setError]=useState(""),[sent,setSent]=useState(false);
 return <div><button type="button" disabled={pending||sent} onClick={()=>start(async()=>{setError("");request.current??=crypto.randomUUID();const result=await resendAgreementDocument(token,document,request.current);if(result.error)setError(result.error);else setSent(true);})}>{pending?"Requesting…":"Resend Agreement Document"}</button>{sent&&<p role="status">Your accepted agreement copy has been queued for email delivery. Please check your inbox and spam folder.</p>}{error&&<p className="notice error" role="alert">{error}</p>}</div>;
}
