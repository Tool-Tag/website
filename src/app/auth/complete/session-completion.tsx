"use client";
import {createBrowserClient} from '@supabase/ssr';
import {useEffect,useRef,useState} from 'react';
import {completeStaffAuth,type StaffAuthResult} from '@/lib/domain/staff-auth';
export function CompleteStaffAuth(){
 const operation=useRef<Promise<StaffAuthResult>|null>(null),[error,setError]=useState('');
 useEffect(()=>{
  let active=true;
  if(!operation.current){
   const fragment=window.location.hash;
   // Remove bearer credentials from history before any rendering or navigation.
   window.history.replaceState(null,'',window.location.pathname+window.location.search);
   const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
   if(!url||!key)operation.current=Promise.resolve({ok:false,error:'Authentication is not configured. Contact the ToolTag Owner.'});
   else{
    try{
     const db=createBrowserClient(url,key,{auth:{detectSessionInUrl:false}});
     operation.current=completeStaffAuth(fragment,db.auth);
    }catch{operation.current=Promise.resolve({ok:false,error:"Authentication is not configured. Contact the ToolTag Owner."});}
   }
  }
  operation.current.then(result=>{if(!active)return;if(result.ok)window.location.replace(result.destination);else setError(result.error);});
  return()=>{active=false;};
 },[]);
 return error?<><p className="notice error" role="alert">{error}</p><a className="button secondary" href="/login">Back to sign in</a></>:<p role="status">Verifying your invitation. You will be able to choose your password next.</p>;
}
