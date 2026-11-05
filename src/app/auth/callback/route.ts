import {staffAuthContinuation,staffAuthDestination} from "@/lib/domain/staff-auth";
import { NextResponse } from "next/server";
import { supabase } from "@/lib/supabase/server";
export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  if (!code) {
    // HTTP redirects without a fragment retain the incoming invite/recovery hash.
    // The browser-only continuation converts it to SSR cookies before /auth/reset.
    const response=NextResponse.redirect(staffAuthContinuation(url.origin,url.searchParams.get("next")));
    response.headers.set("Cache-Control","private, no-store");
    response.headers.set("Referrer-Policy","no-referrer");
    return response;
  }
  if (code) {
    const db = await supabase();
    const { error } = await db.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(staffAuthDestination(url.searchParams.get("next")), url.origin));
  }
  return NextResponse.redirect(new URL("/login", url.origin));
}
