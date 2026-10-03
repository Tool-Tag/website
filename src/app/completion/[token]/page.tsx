import { supabase } from "@/lib/supabase/server";
import { AcceptForm } from "@/components/accept-form";
export const dynamic = "force-dynamic";
export default async function Completion({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data: j, error } = await db.rpc("public_completion", {
    p_token: token,
  });
  if (error || !j)
    return (
      <main className="public">
        <h1>This link is unavailable.</h1>
      </main>
    );
  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Delivery</p>
      <h1>{j.code}</h1>
      <p>
        This acknowledgment confirms that you received the items/work and that
        the delivered work corresponds to what you previously approved. It does
        not waive your general legal or refund rights.
      </p>
      {j.status === "Delivered – Pending Customer Acceptance" ? (
        <div className="grid two">
          <AcceptForm token={token} kind="accept" />
          <AcceptForm token={token} kind="issue" />
        </div>
      ) : (
        <p className="notice">{j.reason ?? j.status}</p>
      )}
    </main>
  );
}
