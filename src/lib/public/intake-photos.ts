import {createHash} from "node:crypto";
import {createClient} from "@supabase/supabase-js";
import type {NextRequest} from "next/server";
export const INTAKE_COOKIE="tooltag_get_tagged_nonce";
export function intakeStorage(){return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.SUPABASE_SECRET_KEY??process.env.SUPABASE_SERVICE_ROLE_KEY!,{auth:{persistSession:false,autoRefreshToken:false}});}
export function intakeNetwork(request:NextRequest){const ip=request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()||request.headers.get("x-real-ip")||"unknown";return createHash("sha256").update((process.env.GET_TAGGED_RATE_SALT??"tooltag-get-tagged-v2")+":"+ip).digest("hex");}
export function validIntakePhotoSession(request:NextRequest,token:string){return request.headers.get("origin")===request.nextUrl.origin&&/^[a-f0-9-]{36}$/i.test(token)&&request.cookies.get(INTAKE_COOKIE)?.value===token;}
