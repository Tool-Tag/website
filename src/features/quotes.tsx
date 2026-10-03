import Link from "next/link";
import { rows } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Badge } from "@/components/ui";
import { Form } from "@/components/form";
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
              initial={items?.map((i) => ({
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
          <Table
            headers={["Artículo", "Grabado", "Cantidad", "Precio unitario"]}
          >
            {items.map((i) => (
              <tr key={i.id}>
                <td>{i.article}</td>
                <td>
                  {i.engraving_type}
                  <br />
                  {i.engraving_text}
                </td>
                <td>{i.quantity}</td>
                <td>{money(i.unit_price)}</td>
              </tr>
            ))}
          </Table>
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
              Genera un enlace privado válido por 7 días desde el primer envío.
              Puedes copiarlo y enviarlo personalmente; email y SMS aún no están
              conectados. Regenerarlo invalida el enlace anterior.
            </p>
            <Form
              operation="send-quote"
              hidden={{ id }}
              fields={[]}
              button="Preparar enlace"
            />
          </Panel>
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
