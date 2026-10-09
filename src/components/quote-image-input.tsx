"use client";
import { useRef, useState } from "react";
export function QuoteImageInput({value,onChange}:{value:string;onChange:(url:string)=>void}) {
 const [busy,setBusy]=useState(false),[error,setError]=useState("");
 const sequence=useRef(0);
 async function upload(file:File) {
  const current=++sequence.current;
  if(!["image/png","image/jpeg","image/webp"].includes(file.type)||file.size>3*1024*1024) {setError("Selecciona PNG, JPG o WebP de hasta 3 MB.");return;}
  setBusy(true);setError("");
  try {
   const body=new FormData();body.set("file",file);
   const response=await fetch("/api/quote-images",{method:"POST",body});
   const result=await response.json();
   if(!response.ok) throw new Error(result.error||"The image could not be uploaded.");
   if(sequence.current===current) onChange(new URL(result.path,window.location.origin).href);
  } catch(e) {if(sequence.current===current)setError(e instanceof Error?e.message:"The image could not be uploaded.");}
  finally {if(sequence.current===current)setBusy(false);}
 }
 return <div>
  <label>Upload Image or Logo<input type="file" accept="image/png,image/jpeg,image/webp" disabled={busy} onChange={e=>{const file=e.target.files?.[0];e.target.value="";if(file)void upload(file);}}/></label>
  <p className="muted">PNG, JPG o WebP · maximum 3 MB. You can also paste a link.</p>
  {busy&&<p role="status">Uploading image…</p>}
  {error&&<p role="alert" className="notice error">{error}</p>}
  {value&&<div style={{position:"relative",maxWidth:280,marginBlock:12,border:"1px solid #39414c",borderRadius:8,padding:12}}>
   {/* eslint-disable-next-line @next/next/no-img-element */}
   <img src={value} alt="Engraving Preview" referrerPolicy="no-referrer" style={{display:"block",width:"100%",height:160,objectFit:"contain"}}/>
   <button type="button" aria-label="Remove Engraving Image" title="Remove Image" onClick={()=>{sequence.current++;setBusy(false);setError("");onChange("");}} style={{position:"absolute",top:4,right:4,width:36,height:36,padding:0,borderRadius:"50%"}}>×</button>
  </div>}
  <label>Image or Logo Link<input type="url" pattern="https?://.*" required value={value} disabled={busy} placeholder="https://…" onChange={e=>onChange(e.target.value)}/></label>
 </div>;
}
