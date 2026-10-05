"use server";
import { dispatchQuoteMail, dispatchWorkerMail } from "@/lib/integrations/mail-dispatch";
import { after } from "next/server";
import { processAcceptedDocument, processAcceptedWorker } from "@/lib/documents/accepted-delivery";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { context, TOOLTAG } from "@/lib/domain/context";
import { supabase } from "@/lib/supabase/server";
import { cents } from "@/lib/domain/money";
import { z } from "zod";
import { createHash, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { loginFailure } from "@/lib/domain/auth-errors";
export type ActionState = { error?: string; ok?: boolean; link?: string; mailStatus?: string; mailRequestedAt?: string; data?: any };
export async function login(
  _: ActionState,
  form: FormData,
): Promise<ActionState> {
  const db = await supabase();
  const { error } = await db.auth.signInWithPassword({
    email: String(form.get("email") ?? "").trim(),
    password: String(form.get("password")),
  });
  if (error) {
    const failure = loginFailure(error);
    const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";
    let projectHost = "invalid-url";
    try {
      projectHost = new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").host;
    } catch {
      /* Log only the configuration category. */
    }
    console.error("[auth.login.failed]", {
      reference: failure.reference,
      status: error.status,
      projectHost,
      keyFingerprint: createHash("sha256")
        .update(key)
        .digest("hex")
        .slice(0, 12),
    });
    return { error: failure.message };
  }
  redirect("/app");
}
export async function logout() {
  const db = await supabase();
  await db.auth.signOut();
  redirect("/login");
}
export async function mutate(
  operation: string,
  back: string,
  _: ActionState,
  form: FormData,
): Promise<ActionState> {
  let destination: string | undefined;
  try {
    const { db, unit, role } = await context();
    if (role !== "admin") return { error: "Esta cuenta es de consulta." };
    const p: Record<string, unknown> = {
      ...Object.fromEntries(form.entries()),
      unit_id: unit,
    };
    for (const [k, v] of Object.entries(p)) {
      if (v === "") delete p[k];
    }
    let name = "",
      args: Record<string, unknown> = { p };
    switch (operation) {
      case "accepted-document": {
        const id = z.uuid().parse(p.id);
        const part = String(p.part || "process");
        if (part === "authorize-live") {
          if (form.get("reconciled")!=="on") return {error:"Confirma el envío al destinatario real antes de autorizar."};
          const {error}=await db.rpc("authorize_document_live_copies",{p_id:id});
          if(error) return {error:error.message};
        } else if (part !== "process") {
          const {error} = await db.rpc("retry_accepted_document", {p_id:id,p_part:part,p_reconciled:form.get("reconciled")==="on"});
          if (error) return {error:error.message};
        }
        const mailStatus = await processAcceptedDocument(db,id);
        revalidatePath("/app","layout");
        return {ok:true,mailStatus};
      }
      case "prepare-accepted-document": {
        const {data:id,error}=await db.rpc("prepare_existing_accepted_document",{p_quote:p.quote_id});
        if(error) return {error:error.message};
        const mailStatus=await processAcceptedDocument(db,id);
        revalidatePath("/app","layout");return {ok:true,mailStatus};
      }
      case "activate-live-mail":
        if (form.get("confirm")!=="on") return {error:"Confirma la activación solo para avisos nuevos."};
        name="activate_customer_mail"; args={}; break;
      case "retry-notification":
        name="retry_customer_notification"; args={p_id:p.id,p_reconciled:form.get("reconciled")==="on"}; break;
      case "request-extension":
        name="request_job_extension"; args={p_job:p.job_id,p_request:p.request,p_key:p.request_key}; break;
      case "extension-send":
        name="send_job_extension"; args={p_id:p.id}; break;
      case "extension-cancel":
        name="cancel_job_extension"; args={p_id:p.id}; break;
      case "generate-receipt":
        name="generate_job_receipt"; args={p_job:p.job_id}; break;
      case "confirm-payment":
        name="confirm_payment_request"; args={p_id:p.id}; break;
      case "customer-stage":
        name="set_job_customer_stage"; args={p_job:p.id,p_stage:p.stage}; break;
      case "customer":
        z.object({
          name: z.string().min(1),
          email: z.email(),
          phone: z.string().min(3),
          address: z.string().min(1),
        }).parse(p);
        name = "save_customer";
        break;
      case "extension-scope":
      case "quote":
        p.items = z
          .array(
            z.object({
              article: z.string().trim().min(1),
              quantity: z.number().int().positive(),
              unit_price: z.string().regex(/^\d+(\.\d{1,2})?$/),
              engraving_type: z.enum(["Text", "Image / Logo", "Fee"]),
              engraving_text: z.string(),
              width_mm: z.string(),
              height_mm: z.string(),
              paint_fill: z.boolean(),
              colors: z.number().int().min(0),
              paint_details: z
                .object({
                  mode: z.enum(["single", "multiple"]),
                  color: z.string(),
                  instructions: z.string(),
                })
                .optional(),
              notes: z.string(),
              marks: z
                .array(
                  z.discriminatedUnion("type", [
                    z.object({
                      type: z.literal("Text"),
                      location: z.string().trim().min(1),
                      description: z.string().optional(),
                      paint_fill: z.boolean().optional(),
                      paint_details: z.object({ mode: z.enum(["single", "multiple"]), color: z.string(), instructions: z.string() }).optional(),
                      text: z.string().trim().min(1),
                      url: z.string(),
                    }),
                    z.object({
                      type: z.literal("Image / Logo"),
                      location: z.string().trim().min(1),
                      description: z.string().optional(),
                      paint_fill: z.boolean().optional(),
                      paint_details: z.object({ mode: z.enum(["single", "multiple"]), color: z.string(), instructions: z.string() }).optional(),
                      text: z.string(),
                      url: z.url().refine((v) => /^https?:\/\//.test(v)),
                    }),
                  ]),
                )
                .default([]),
            }),
          )
          .min(1)
          .parse(JSON.parse(String(p.items)))
          .map((item, index) => {
            if (item.engraving_type !== "Fee" && !item.marks.length)
              throw new Error("Agrega al menos un grabado con su ubicación.");
            for (const mark of item.marks) {
              if (mark.paint_fill && (!mark.paint_details || (mark.paint_details.mode === "single" ? !mark.paint_details.color.trim() : !mark.paint_details.instructions.trim())))
                throw new Error("Especifica el color o las instrucciones de pintura del grabado.");
            }
            return { ...item, sort_order: index };
          });
        name = operation === "extension-scope" ? "save_job_extension" : "create_quote";
        break;
      case "movement":
        cents(String(p.amount));
        name = "record_movement";
        break;
      case "asset":
        name = "create_asset";
        break;
      case "document":
        name = "add_document";
        break;
      case "update-transaction":
        name = "update_transaction";
        break;
      case "publish-policy":
        name = "publish_policy";
        args = { p_unit: unit, p_title: p.title, p_content: p.content };
        break;
      case "resend-quote":
        name = "resend_quote";
        args = { p_id: p.id };
        break;
      case "get-tagged-approve":
        name = "approve_get_tagged";
        args = { p_id: p.id, p_customer: p.customer_id ?? null };
        break;
      case "get-tagged-reject":
        name = "reject_get_tagged";
        args = { p_id: p.id, p_reason: p.reason ?? null };
        break;
      case "send-quote":
        name = form.get("resend") === "true" ? "resend_quote" : "send_quote_to";
        args = form.get("resend") === "true" ? { p_id: p.id } : { p_id: p.id, p_recipient: String(form.get("recipient") || "").trim(), p_regenerate: form.get("regenerate") === "on" };
        break;
      case "job":
        name = "advance_job";
        args = { p_id: p.id, p_action: p.action };
        break;
      case "job-item":
        name = "advance_job_item";
        args = { p_item: p.item_id, p_action: p.action };
        break;
      case "complete-job-work":
        name = "complete_job_work";
        args = { p_job: p.id };
        break;
      case "pick-return-schedule":
        name = "schedule_pick_return";
        args = {
          p_job: p.job_id,
          p_leg: p.leg,
          p_window_start: p.window_start,
          p_window_end: p.window_end,
          p_eta: p.eta ?? null,
        };
        break;
      case "pick-return-stop":
        name = "advance_pick_return_stop";
        args = { p_stop: p.stop_id, p_action: p.action };
        break;
      case "cancellation-refund":
        name = "confirm_cancellation_refund";
        args = { p_request: p.request_id, p_method: p.method, p_reference: p.reference ?? null };
        break;
      case "notified":
        name = "confirm_completion_notified";
        args = { p_id: p.id };
        break;
      case "close":
        name = "close_month";
        args = { p_unit: unit, p_month: p.month };
        break;
      case "settings":
        name = "save_settings";
        break;
      case "mileage":
        name = "record_mileage";
        break;
      case "category":
        name = "save_category";
        break;
      default:
        return { error: "Acción desconocida" };
    }
    const { data, error } = await db.rpc(name, args);
    if (error) return { error: error.message };
    revalidatePath("/app", "layout");
    if (operation === "send-quote" || operation === "resend-quote") return { mailRequestedAt: new Date().toISOString(), link: `/review/${data}`, mailStatus: await dispatchQuoteMail(db, String(p.id)) };
    if (["job","job-item","complete-job-work","pick-return-schedule","pick-return-stop","document","movement","extension-send","extension-cancel","generate-receipt","retry-notification","confirm-payment","cancellation-refund"].includes(operation)) await dispatchWorkerMail();
    if (operation === "extension-send") return {link:`/extension/${data}`};
    if ((operation === "job" || operation === "complete-job-work") && data) return { link: `/completion/${data}` };
    if (operation === "get-tagged-approve" && data) destination = `/app/quotes/${data}`;
    else if (operation === "get-tagged-reject") destination = "/app/get-tagged";
    else if (operation === "customer") destination = `/app/customers/${data}`;
    else if (operation === "request-extension") destination=`/app/job-extensions/${data}`;
    else if (operation === "extension-scope") destination=`/app/job-extensions/${data}`;
    else if (operation === "quote") destination = `/app/quotes/${data}`;
    else if (operation === "movement" && p.type === "EXPENSE")
      destination = `/app/finance/expenses?created=${data}`;
    else if (back.startsWith("/app") || back.startsWith("/pick-return")) destination = back;
  } catch (e) {
    return { error: e instanceof Error ? e.message : "No se pudo guardar" };
  }
  if (destination) redirect(destination);
  return { ok: true };
}
export async function customerAction(
  kind: string,
  token: string,
  _: ActionState,
  form: FormData,
): Promise<ActionState> {
  const db = await supabase();
  if (["work-ready","work-additional","extension-accept"].includes(kind)) {
    if(kind==="extension-accept" && form.get("confirmed")!=="on") return {error:"Confirm the additional scope and price."};
    const {error}= kind==="extension-accept"
      ? await db.rpc("public_extension",{p_token:token,p_accept:true,p_name:String(form.get("name")||"").trim()})
      : await db.rpc("public_work_review",{p_token:token,p_response:kind==="work-ready"?"ready":"additional",p_request:String(form.get("request")||"").trim()});
    if(error) return {error:error.message};
    revalidatePath(`/work/${token}`);revalidatePath(`/extension/${token}`);revalidatePath("/app","layout");return {ok:true};
  }
  if (kind === "payment" || kind === "pickup-payment") {
    const pickupFee = kind === "pickup-payment";
    const method = String(form.get("method") || "");
    const requestKey = randomUUID();
    let proofPath: string | null = null;
    const file = form.get("proof");

    if (pickupFee ? !["Zelle", "Venmo"].includes(method) : !["Cash", "Zelle", "Venmo"].includes(method))
      return { error: pickupFee ? "Choose Zelle or Venmo." : "Choose Cash, Zelle or Venmo." };

    if (method !== "Cash") {
      if (!(file instanceof File) || file.size === 0)
        return { error: "Upload a screenshot of your Zelle or Venmo payment." };
      if (file.size > 5 * 1024 * 1024)
        return { error: "Payment proof must be 5 MB or smaller." };

      const extensions: Record<string, string> = {
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/webp": "webp",
      };
      const ext = extensions[file.type];
      if (!ext) return { error: "Use a PNG, JPG, or WebP screenshot." };

      const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
      const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
      if (!url || !key) return { error: "Payment upload is not configured." };

      const admin = createClient(url, key, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      proofPath = `${TOOLTAG}/${requestKey}.${ext}`;
      const bytes = new Uint8Array(await file.arrayBuffer());
      const { error: uploadError } = await admin.storage
        .from("payment-proofs")
        .upload(proofPath, bytes, { contentType: file.type, upsert: false });
      if (uploadError) return { error: "Could not upload payment proof." };
    }

    const { error } = pickupFee
      ? await db.rpc("public_submit_pickup_fee_payment", {
          p_token: token,
          p_request: requestKey,
          p_method: method,
          p_proof_path: proofPath,
        })
      : await db.rpc("public_submit_payment_request", {
          p_token: token,
          p_request: requestKey,
          p_method: method,
          p_proof_path: proofPath,
        });

    if (error) {
      if (proofPath) {
        const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
        const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
        if (url && key) {
          const admin = createClient(url, key, {
            auth: { persistSession: false, autoRefreshToken: false },
          });
          await admin.storage.from("payment-proofs").remove([proofPath]);
        }
      }
      return { error: error.message };
    }

    await dispatchWorkerMail();
    if (pickupFee) {
      revalidatePath(`/pickup/${token}/payment`);
      revalidatePath("/app", "layout");
      return { ok: true };
    }
    revalidatePath(`/completion/${token}`);
    revalidatePath("/app", "layout");
    return { ok: true, link: `/payment/${token}/confirmation` };
  }
  if (kind === "review") {
    const { error } = await db.rpc("accept_review", {
      p_token: token,
      p_quote_confirmed: form.get("quote_confirmed") === "on",
      p_agreement_confirmed: form.get("agreement_confirmed") === "on",
      p_name: String(form.get("name") ?? "").trim(),
      p_email: String(form.get("email") ?? "").trim(),
      p_phone: String(form.get("phone") ?? "").trim(),
    });
    if (error) return { error: error.message };
    after(async () => {
      await processAcceptedWorker();
      await dispatchWorkerMail();
    });
    revalidatePath(`/review/${token}`);
    revalidatePath(`/accept/${token}`);
    revalidatePath("/app", "layout");
    return { ok: true };
  }
  if (!["accept", "issue"].includes(kind))
    return { error: "Use the combined quote and Agreement review page." };
  const { error } = await db.rpc("public_completion", {
    p_token: token,
    p_decision: kind,
  });
  if (error) return { error: error.message };
  await dispatchWorkerMail();
  revalidatePath(`/completion/${token}`);
  return kind === "accept"
    ? { ok: true, link: `/payment/${token}` }
    : { ok: true };
}
