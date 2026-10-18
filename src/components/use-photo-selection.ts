"use client";
import {useRef,useState,type ChangeEvent} from "react";
import {normalizePhoto} from "@/lib/photos/normalize";
export function usePhotoSelection(validate?:(file:File)=>string|null){
 const [preparing,setPreparing]=useState(false),[error,setError]=useState("");const revision=useRef(0);
 async function onChange(event:ChangeEvent<HTMLInputElement>){
  const input=event.currentTarget,file=input.files?.[0],current=++revision.current;setError("");
  if(!file){setPreparing(false);input.setCustomValidity("");return;}
  setPreparing(true);input.setCustomValidity("Preparing your photo. Please wait.");
  try{
   const normalized=await normalizePhoto(file);if(current!==revision.current)return;
   const message=validate?.(normalized)||"";
   if(normalized!==file){const transfer=new DataTransfer();transfer.items.add(normalized);input.files=transfer.files;}
   input.setCustomValidity(message);setError(message);
  }catch(e){if(current===revision.current){const message=e instanceof Error?e.message:"Unable to prepare the photo.";input.value="";input.setCustomValidity(message);setError(message);}}
  finally{if(current===revision.current)setPreparing(false);}
 }
 return {preparing,error,onChange};
}
