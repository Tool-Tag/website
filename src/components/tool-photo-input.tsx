"use client";
import {normalizePhoto,PHOTO_ACCEPT} from "@/lib/photos/normalize";
import Image from "next/image";
import {useEffect,useRef,useState} from "react";
export function ToolPhotoInput({token,value,onChange}:{token:string;value:string;onChange:(id:string)=>void}){
 const camera=useRef<HTMLInputElement>(null);const [dragging,setDragging]=useState(false);
 const [busy,setBusy]=useState(false),[error,setError]=useState(""),[preview,setPreview]=useState("");const sequence=useRef(0);
 useEffect(()=>()=>{sequence.current++;},[]);
 useEffect(()=>()=>{if(preview)URL.revokeObjectURL(preview);},[preview]);
 async function upload(file:File){const n=++sequence.current;setBusy(true);setError("");try{
  file=await normalizePhoto(file);
  if(!["image/png","image/jpeg","image/webp"].includes(file.type)||file.size>3*1024*1024)throw new Error("Use a PNG, JPG or WebP photo up to 3 MB.");
  const form=new FormData();form.set("token",token);form.set("file",file);
  const response=await fetch("/api/get-tagged/photos",{method:"POST",body:form}),data=await response.json();if(!response.ok)throw new Error(data.error||"Photo could not be uploaded.");
  if(sequence.current===n){onChange(data.id);setPreview(URL.createObjectURL(file));}
 }catch(e){if(sequence.current===n)setError(e instanceof Error?e.message:"Unable to upload photo.");}finally{if(sequence.current===n)setBusy(false);}}
 return <section className={`tool-photo-input photo-dropzone${dragging?' dragging':''}`} onDragOver={e=>{e.preventDefault();setDragging(true);}} onDragLeave={()=>setDragging(false)} onDrop={e=>{e.preventDefault();setDragging(false);const file=e.dataTransfer.files[0];if(file&&!busy&&token)void upload(file);}}><h4>Tool photo (optional)</h4><p>A photo can help us review your request. You may continue without one.</p><p>Drop a photo here, upload a file, or use your camera.</p><div className="photo-choice-buttons"><button type="button" disabled={busy||!token} onClick={()=>camera.current?.click()}>Take photo</button><input hidden ref={camera} type="file" accept={PHOTO_ACCEPT} capture="environment" onChange={e=>{const file=e.target.files?.[0];e.target.value='';if(file)void upload(file);}}/><label>Upload<input type="file" accept={PHOTO_ACCEPT} disabled={busy||!token} onChange={e=>{const file=e.target.files?.[0];e.target.value="";if(file)void upload(file);}}/></label></div>{busy&&<p role="status">Uploading optional photo… You can still submit without it.</p>}{error&&<p role="alert">{error} The photo is optional.</p>}{value&&<div className="tool-photo-preview">{preview?<Image unoptimized src={preview} alt="Tool photo preview" width={280} height={180}/>:<p>Tool photo uploaded.</p>}<button type="button" aria-label="Remove tool photo" onClick={()=>{sequence.current++;setBusy(false);setPreview("");onChange("");}}>Remove</button></div>}</section>;
}
