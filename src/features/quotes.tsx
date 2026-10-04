import { AcceptedDocuments } from "@/components/accepted-documents";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Badge } from "@/components/ui";
import { SendQuote } from "@/components/send-quote";
import { QuoteScope } from "@/components/quote-scope";
import { QuoteBuilder } from "@/components/quote-builder";
import { money, quoteTotal } from "@/lib/domain/money";
export async function Quotes({
  id,
  customer,
  revise,
}: {
  id?: string;
  customer?: string;
  revise?: string;
}) {
  if (id === "new") {
    const customers = await rows("customers");
    const original = revise ? (await rows("quotes", { id: revise }))[0] : null;
    const originalFlow = original
      ? (await rows("commercial_flows", { id: original.flow_id }))[0]
      : null;
    const items = original
      ? await rows("quote_items", { field: "quote_id", value: original.id })
      : undefined;
    return (
      <>
        <Heading
          title={revise ? "Revisar cotización" : "Nueva cotización"}
          subtitle="Cada revisión conserva lo que el cliente aprobó anteriormente."
        />
        <Panel>
          {customers.length ? (
            <QuoteBuilder
              customers={customers.map((c) => ({ id: c.id, name: c.name }))}
              customer={originalFlow?.customer_id ?? customer}
              revises={revise}
              notes={original?.notes ?? ""}
              initial={items?.map((i) => ({
                marks: i.marks,
                paint_details: i.paint_details?.mode
                  ? i.paint_details
                  : undefined,
                adaptation_fee: i.adaptation_fee,
                paint_fee: i.paint_fee,
                additional_engraving_fee: i.additional_engraving_fee,
                article: i.article,
                quantity: i.quantity,
                engraving_type: i.engraving_type,
                engraving_text: i.engraving_text ?? "",
                width_mm: String(i.width_mm ?? ""),
                height_mm: String(i.height_mm ?? ""),
                paint_fill: i.paint_fill,
                colors: i.colors,
                unit_price: String(i.unit_price),
                notes: i.notes ?? "",
              }))}
            />
          ) : (
            <Empty>
              <Link href="/app/customers/new">Primero agrega un cliente →</Link>
            </Empty>
          )}
        </Panel>
      </>
    );
  }
  if (id) {
    const q = (await rows("quotes", { id }))[0];
    if (!q) return <Empty>Cotización no encontrada.</Empty>;
    const flow = (await rows("commercial_flows", { id: q.flow_id }))[0];
    const contact = flow ? (await rows("customers", { id: flow.customer_id }))[0] : null;
    const {db}=await context();
    const delivery=q.sent_at ? (await db.rpc("quote_delivery",{p_id:id})).data : null;
    const items = await rows("quote_items", { field: "quote_id", value: id });
    const jobs = await rows("jobs", { field: "flow_id", value: q.flow_id });
    return (
      <>
        <Heading title={q.code} subtitle={`Versión ${q.revision}`}>
          <Badge>{q.status}</Badge>
          <Link
            className="button secondary"
            href={`/app/quotes/new?revise=${q.id}`}
          >
            Crear revisión
          </Link>
        </Heading>
        <Panel title="Artículos aprobables">
          <QuoteScope items={items} />
          <h2 style={{ marginTop: 20 }}>
            Total:{" "}
            {money(
              quoteTotal(
                items.map((i) => ({
                  quantity: i.quantity,
                  unit_price: String(i.unit_price),
                })),
              ),
            )}
          </h2>
          <p>{q.notes}</p>
        </Panel>
        {["Draft", "Sent", "Viewed"].includes(q.status) && (
          <Panel title="Compartir con el cliente">
            <p className="muted">
              Envía al cliente un enlace privado para revisar la cotización y
              aceptar el Agreement. El enlace será válido por 7 días desde el
              primer envío. El destinatario elegido queda fijado para esta versión.
              También puedes copiar el enlace y ver el correo preparado.
            </p>
            <SendQuote id={id} email={delivery?.recipient || contact?.email} companyEmail={delivery?.recipient ? undefined : contact?.company_email} />
          </Panel>
        )}
        <AcceptedDocuments quoteId={id} />
        {q.status === "Accepted" && (
          <p>
            <Link href={`/app/quotes/${id}/email`}>
              Vista previa de la confirmación
            </Link>
          </p>
        )}
        {jobs.map((j) => (
          <Panel key={j.id}>
            <Link href={`/app/jobs/${j.id}`}>Abrir {j.code} →</Link>
          </Panel>
        ))}
      </>
    );
  }
  const list = await rows("quotes", { order: "created_at" });
  return (
    <>
      <Heading
        title="Cotizaciones"
        subtitle="Precio manual. Aprobación y términos versionados."
      >
        <Link className="button" href="/app/quotes/new">
          + Nueva cotización
        </Link>
      </Heading>
      <Panel>
        {list.length ? (
          <Table headers={["Cotización", "Versión", "Estado", "Vigencia"]}>
            {list.map((q) => (
              <tr key={q.id}>
                <td>
                  <Link href={`/app/quotes/${q.id}`}>{q.code}</Link>
                </td>
                <td>{q.revision}</td>
                <td>
                  <Badge>{q.status}</Badge>
                </td>
                <td>
                  {q.expires_at
                    ? new Date(q.expires_at).toLocaleDateString("es-US")
                    : "Sin enviar"}
                </td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty />
        )}
      </Panel>
    </>
  );
}
