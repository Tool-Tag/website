import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
import { parseVerifiedStripeEvent } from "@/lib/payments/stripe";

export const dynamic = "force-dynamic";

function adminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key =
    process.env.SUPABASE_SECRET_KEY ??
    process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) throw new Error("Supabase server credentials are missing.");

  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function POST(request: Request) {
  const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET?.trim();
  const signature = request.headers.get("stripe-signature");
  if (!endpointSecret || !signature) {
    return NextResponse.json(
      { error: "Card webhook is not configured." },
      { status: 503 },
    );
  }

  const rawBody = await request.text();
  let event;
  try {
    event = parseVerifiedStripeEvent(rawBody, signature, endpointSecret);
  } catch {
    return NextResponse.json(
      { error: "Invalid webhook signature." },
      { status: 400 },
    );
  }

  if (
    ![
      "checkout.session.completed",
      "checkout.session.async_payment_succeeded",
    ].includes(event.type)
  ) {
    return NextResponse.json({ received: true });
  }

  const session = event.data.object;
  if (session.payment_status !== "paid") {
    return NextResponse.json({ received: true });
  }

  const attemptId =
    session.metadata?.attempt_id || session.client_reference_id || "";
  const amountTotal = session.amount_total;

  if (!attemptId || !session.id || amountTotal == null) {
    return NextResponse.json(
      { error: "Stripe event is missing payment metadata." },
      { status: 400 },
    );
  }

  const db = adminClient();
  const { error } = await db.rpc("confirm_logistics_card_payment", {
    p_attempt: attemptId,
    p_provider_reference: session.id,
    p_amount: (amountTotal / 100).toFixed(2),
  });

  if (error) {
    console.error("[stripe.webhook.confirm.failed]", {
      eventId: event.id,
      reference: session.id,
      message: error.message,
    });
    return NextResponse.json(
      { error: "Payment confirmation could not be recorded." },
      { status: 500 },
    );
  }

  await dispatchWorkerMail();
  return NextResponse.json({ received: true });
}
