import { SMS_CONSENT_DISCLOSURE, SMS_POLICY_ACCEPTANCE, smsPolicyLinks } from "@/lib/domain/sms-consent";
import { normalizeSmsPhone } from "@/lib/integrations/sms";
import { PHONE_VERIFICATION_COOKIE, verifiedPhone } from "@/lib/integrations/phone-verification";
import { createHash, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { after, NextRequest, NextResponse } from "next/server";
import {dispatchWorkerMail} from "@/lib/integrations/mail-dispatch";
import {
  PICKUP_FEE,
  PICKUP_REQUEST_DISCLAIMER,
  getTaggedQuoteItems,
  getTaggedRequestSchema,
} from "@/lib/public/get-tagged";

export const dynamic = "force-dynamic";

const NONCE_COOKIE = "tooltag_get_tagged_nonce";
const SIX_HOURS = 60 * 60 * 6;

function noStore<T>(response: NextResponse<T>) {
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.set("Referrer-Policy", "no-referrer");
  return response;
}

function serverClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key =
    process.env.SUPABASE_SECRET_KEY ??
    process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error("Get Tagged service is not configured.");
  }

  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function networkFingerprint(request: NextRequest) {
  const ip =
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    request.headers.get("x-real-ip") ||
    "unknown";
  const salt = process.env.GET_TAGGED_RATE_SALT ?? "tooltag-get-tagged-v2";
  return createHash("sha256").update(salt + ":" + ip).digest("hex");
}

function validOrigin(request: NextRequest) {
  const origin = request.headers.get("origin");
  if (!origin) return true;
  return origin === request.nextUrl.origin;
}

function publicError(message: string) {
  if (message.includes("Request rate limit")) {
    return {
      status: 429,
      message: "Too many requests. Please try again later.",
    };
  }
  if (message.includes("On-site service is temporarily unavailable")) {
    return {
      status: 400,
      message: "On-site service is temporarily unavailable. Choose Drop-off or Pickup & Delivery.",
    };
  }
  if (
    message.includes("Invalid request") ||
    message.includes("Request already submitted")
  ) {
    return {
      status: 400,
      message: "Review your request details and try again.",
    };
  }
  return {
    status: 500,
    message: "We could not submit your request right now. Please try again.",
  };
}

export async function GET() {
  const token = randomUUID();
  const response = NextResponse.json({ token });

  response.cookies.set(NONCE_COOKIE, token, {
    httpOnly: true,
    sameSite: "strict",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: SIX_HOURS,
  });

  return noStore(response);
}

export async function POST(request: NextRequest) {
  try {
    if (!validOrigin(request)) {
      return noStore(
        NextResponse.json(
          { error: "Unable to submit this request.", refresh: true },
          { status: 403 },
        ),
      );
    }

    const contentLength = Number(request.headers.get("content-length") || 0);
    if (contentLength > 150_000) {
      return noStore(
        NextResponse.json(
          { error: "This request is too large." },
          { status: 413 },
        ),
      );
    }

    const body = await request.json();
    const token = String(body?.token ?? "");
    const cookieToken = request.cookies.get(NONCE_COOKIE)?.value ?? "";

    if (!token || !cookieToken || token !== cookieToken) {
      return noStore(
        NextResponse.json(
          {
            error: "Your form session expired. Refresh the form and try again.",
            refresh: true,
          },
          { status: 409 },
        ),
      );
    }

    if (String(body?.website ?? "").trim()) {
      return noStore(NextResponse.json({ reference: "TT-R-RECEIVED" }));
    }

    const parsed = getTaggedRequestSchema.safeParse(body?.request);
    if (!parsed.success) {
      return noStore(
        NextResponse.json(
          {
            error:
              parsed.error.issues[0]?.message ??
              "Review your request details and try again.",
          },
          { status: 400 },
        ),
      );
    }

    const customerRequest = parsed.data;
    if (customerRequest.contact.phone && !(await verifiedPhone(customerRequest.contact.phone, request.cookies.get(PHONE_VERIFICATION_COOKIE)?.value))) return noStore(NextResponse.json({error:"Verify your phone number before submitting your request."},{status:400}));
    const links=smsPolicyLinks(), smsPhone=normalizeSmsPhone(customerRequest.sms_phone || customerRequest.contact.phone);
    if(customerRequest.sms_opt_in && (!links || !smsPhone || !customerRequest.sms_policy_accepted)) return noStore(NextResponse.json({error:"SMS updates require a valid mobile number and acceptance of Terms of Service and Privacy Policy."},{status:400}));
    const photoIds=customerRequest.items.map(i=>i.photo_id).filter(Boolean);
    if(photoIds.length){const photos=await serverClient().from("get_tagged_tool_photos").select("id").eq("request_key",token).eq("stored",true).in("id",photoIds);const valid=new Set((photos.data??[]).map(p=>p.id));customerRequest.items=customerRequest.items.map(item=>({...item,photo_id:!photos.error&&valid.has(item.photo_id)?item.photo_id:""}));}
    const pickup = customerRequest.service.method === "Pickup";

    const payload = {
      ...customerRequest,
      sms: {granted:customerRequest.sms_opt_in,phone:smsPhone || "",privacy_url:links?.privacy || "",terms_url:links?.terms || "",policy_accepted:customerRequest.sms_policy_accepted,disclosure:SMS_CONSENT_DISCLOSURE+"\n"+SMS_POLICY_ACCEPTANCE},
      service: pickup
        ? {
            ...customerRequest.service,
            method: "Pickup",
            logistics_option: "pickup_delivery",
            logistics_fee: PICKUP_FEE,
            logistics_note: PICKUP_REQUEST_DISCLAIMER,
          }
        : customerRequest.service,
      quote_items: getTaggedQuoteItems(customerRequest),
    };

    const db = serverClient();
    const { data, error } = await db.rpc("submit_get_tagged", {
      p_key: token,
      p_network: networkFingerprint(request),
      p_payload: payload,
    });

    if (error) {
      const mapped = publicError(error.message);
      return noStore(
        NextResponse.json(
          { error: mapped.message },
          { status: mapped.status },
        ),
      );
    }

    const reference = String(data?.reference ?? "");
    if (!reference) {
      return noStore(
        NextResponse.json(
          { error: "We could not confirm your request. Please try again." },
          { status: 500 },
        ),
      );
    }

    after(()=>dispatchWorkerMail());
    return noStore(
      NextResponse.json({
        reference,
        status: data?.status ?? "Pending",
      }),
    );
  } catch {
    return noStore(
      NextResponse.json(
        { error: "We could not submit your request right now. Please try again." },
        { status: 500 },
      ),
    );
  }
}
