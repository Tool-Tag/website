import { context } from "@/lib/domain/context";
import {
  renderQuoteMail,
} from "@/lib/integrations/quote-mail";
import { headers } from "next/headers";
export default async function EmailPreview({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const { db } = await context();
  const { data, error } = await db.rpc("quote_delivery", { p_id: id });
  if (error || !data?.token)
    return (
      <p>
        Envía la cotización para preparar el enlace y la vista previa del
        correo.
      </p>
    );
  const h = await headers();
  const origin =
    process.env.TOOLTAG_PUBLIC_URL ||
    `${h.get("x-forwarded-proto") || "http"}://${h.get("host")}`;
  const url = new URL(`/review/${data.token}`, origin).toString();
  const mail = renderQuoteMail(
    data.snapshot,
    url,
    data.accepted ? "confirmation" : "quote",
    data.job_code,
  );
  if (!data.accepted && data.recipient) mail.to = data.recipient;
  return (
    <>
      <h1>Vista previa del correo</h1>
      <p>Esta vista previa no envía correos. Consulta el estado de entrega en Ajustes.</p>
      <p>
        De: {mail.from} · Para: {mail.to} · Responder a: {mail.replyTo}
      </p>
      <h2>{mail.subject}</h2>
      <iframe
        title="Correo HTML"
        sandbox=""
        srcDoc={mail.html}
        style={{ width: "100%", height: 650, border: 0 }}
      />
      <details>
        <summary>Versión de texto</summary>
        <pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>
          {mail.text}
        </pre>
      </details>
    </>
  );
}
