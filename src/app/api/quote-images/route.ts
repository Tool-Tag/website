import { createHash } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { context } from "@/lib/domain/context";
export async function POST(request:NextRequest) {
 const {db,role,unit}=await context();
 if(role!=="admin") return NextResponse.json({error:"Acceso no autorizado."},{status:403});
 if(Number(request.headers.get("content-length")||0)>3300000) return NextResponse.json({error:"Maximum 3 MB."},{status:413});
 const form=await request.formData(),file=form.get("file");
 if(!(file instanceof File)||file.size===0||file.size>3*1024*1024) return NextResponse.json({error:"Select an image up to 3 MB."},{status:400});
 const bytes=Buffer.from(await file.arrayBuffer());
 const type=bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))?"image/png":bytes[0]===255&&bytes[1]===216&&bytes[2]===255?"image/jpeg":bytes.toString("ascii",0,4)==="RIFF"&&bytes.toString("ascii",8,12)==="WEBP"?"image/webp":null;
 if(!type||type!==file.type) return NextResponse.json({error:"Use a valid PNG, JPG, or WebP file."},{status:400});
 const key=`${unit}/${createHash("sha256").update(bytes).digest("hex")}`;
 const {error}=await db.storage.from("quote-images").upload(key,bytes,{contentType:type,upsert:false});
 if(error) {
  const existing=await db.storage.from("quote-images").download(key);
  if(existing.error) return NextResponse.json({error:"Could not save the image. Check that storage is configured."},{status:503});
 }
 return NextResponse.json({path:`/api/quote-images/${key.split("/")[1]}`});
}
