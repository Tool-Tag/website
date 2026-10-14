import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL,
    key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) return response;
  const client = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(values) {
        values.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        values.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options),
        );
      },
    },
  });
  const {data:{user}} = await client.auth.getUser();
  if (user && request.nextUrl.pathname !== "/login") {
    const {data:session,error} = await client.rpc("staff_session_state");
    if (error || !session?.active) {
      await client.auth.signOut({scope:"local"});
      const expired = NextResponse.redirect(new URL("/login?notice=session-expired",request.url));
      response.cookies.getAll().forEach(cookie=>expired.cookies.set(cookie));
      expired.headers.set("Cache-Control","private, no-store");
      return expired;
    }
  }
  response.headers.set("Cache-Control", "private, no-store");
  return response;
}
export const config = { matcher: ["/app/:path*", "/pick-return/:path*", "/login", "/auth/:path*"] };
