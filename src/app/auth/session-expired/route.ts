import { NextResponse } from "next/server";
import { supabase } from "@/lib/supabase/server";
export async function GET(request: Request) {
  const db = await supabase();
  const {data:session,error} = await db.rpc("staff_session_state");
  if (!error && session?.active) return NextResponse.redirect(new URL("/app",request.url));
  await db.auth.signOut({scope:"local"});
  const response=NextResponse.redirect(new URL("/login?notice=session-expired",request.url));
  response.headers.set("Cache-Control","private, no-store");
  return response;
}
