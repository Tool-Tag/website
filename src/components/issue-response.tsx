"use client";
import {useState,useTransition} from "react";
import {recordIssueResponse} from "@/app/issue-response-actions";
import {useAccess} from "./permission-provider";
import {can} from "@/lib/auth/permissions";
export function IssueResponse({job,responded}:{job:string;responded:boolean}){
 const access=useAccess();const [error,setError]=useState("");const [pending,start]=useTransition();
 if(responded)return <p>Customer response recorded.</p>;
 if(!can(access,"jobs.manage"))return null;
 return <><p>Record this only after you have actually responded to the customer. This does not resolve the issue or send a message.</p><button disabled={pending} onClick={()=>{if(window.confirm("Confirm that the customer has received your response?"))start(async()=>{const result=await recordIssueResponse(job);setError(result.error??"");});}}>Record customer response</button>{error&&<p role="alert">{error}</p>}</>;
}
