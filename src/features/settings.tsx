import { rows, context } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty } from "@/components/ui";
import { Form } from "@/components/form";
export async function Settings() {
  const [settings, policies, notifications, categories] = await Promise.all([
    rows("unit_settings"),
    rows("policies", { order: "version" }),
    rows("notifications", { order: "created_at", limit: 30 }),
    rows("categories"),
  ]);
  const {db,role}=await context();
  const {data:mail}=await db.rpc("customer_mail_status");
  const s = settings[0];
  return (
    <>
      <Heading
        title="Configuración"
        subtitle="ToolTag · Bandits of the Framing LLC"
      />
      <Panel title="Correo de producción">
        <p>Modo del servidor: {process.env.TOOLTAG_MAIL_MODE || "preview"}</p>
        <p>Inicio de avisos elegibles: {mail?.activated_at || "Pendiente de activar"}</p>
        <p>La activación no reenvía pruebas ni notificaciones históricas. Los fallos requieren un reintento individual.</p>
        {role==="admin" && !mail?.activated_at && <Form operation="activate-live-mail" fields={[]} button="Habilitar avisos nuevos" back="/app/settings"><label className="checkbox"><input type="checkbox" name="confirm" required/>Activar únicamente los avisos nuevos desde este momento.</label></Form>}
        <p className="muted">Para entregar a clientes, Vercel debe tener TOOLTAG_MAIL_MODE=live. Esta pantalla no modifica variables de Vercel.</p>
      </Panel>
      <Panel title="Google Drive"><p>Preparado visualmente · pendiente de configurar. Subidas y vistas previas desactivadas.</p><pre style={{whiteSpace:"pre-wrap"}}>ToolTag Customers / Cliente / Jobs / Trabajo / Agreement, Receiving, Completed, Payments, Issue-Review, Other</pre></Panel>
      <Panel title="Acuerdos / políticas">
        <p className="notice">
          No se ha inventado texto legal. Publica únicamente el texto aprobado.
          Cada versión queda preservada; las aceptaciones anteriores conservan
          su contenido.
        </p>
        {policies.map((p) => (
          <details key={p.id}>
            <summary>
              {p.title} · v{p.version}
            </summary>
            <div className="policy">{p.content}</div>
          </details>
        ))}
        <details>
          <summary>Publicar una nueva versión aprobada</summary>
          <Form
            operation="publish-policy"
            fields={[
              { name: "title", label: "Título", required: true },
              {
                name: "content",
                label: "Texto exacto aprobado (inglés)",
                type: "textarea",
                required: true,
                wide: true,
              },
            ]}
            back="/app/settings"
            button="Publicar versión"
          />
        </details>
      </Panel>
      <div className="grid two">
        <Panel title="Reglas vigentes">
          <p>Cotización: 7 días · Recordatorio: 2 días antes.</p>
          <p>Revisión de devolución: 14 días.</p>
          <p>Aceptación de entrega: 3 días después de notificar.</p>
          <p>Cierre mensual: día 1, mes anterior.</p>
          <p>Pagos: Cash, Zelle, Venmo.</p>
        </Panel>
        <Panel title="Documentos / Drive">
          <p className="muted">
            Integración de subida pendiente. Puedes vincular archivos reales
            existentes por su Drive File ID.
          </p>
          <Form
            operation="settings"
            fields={[
              {
                name: "drive_root_id",
                label: "Carpeta raíz de ToolTag Customers",
                value: s?.drive_root_id ?? "",
              },
              {
                name: "timezone",
                label: "Zona horaria",
                value: s?.timezone ?? "America/Denver",
              },
              {
                name: "boft_url",
                label: "URL del BOFT System",
                type: "url",
                value: s?.boft_url ?? "",
              },
              {
                name: "annual_vehicle_method",
                label: "Método del reporte anual de vehículo",
                value: s?.annual_vehicle_method ?? "Fuel",
                options: [
                  { value: "Fuel", label: "Fuel" },
                  { value: "Mileage", label: "Travel / Mileage" },
                ],
              },
              {
                name: "mileage_rate",
                label: "Tarifa por milla para análisis (opcional)",
                value: s?.mileage_rate ?? "",
                type: "number",
              },
            ]}
            back="/app/settings"
          />
        </Panel>
      </div>
      <Panel title="Categorías">
        <Table headers={["Nombre", "Tipo", "Estado"]}>
          {categories.map((c) => (
            <tr key={c.id}>
              <td>{c.name}</td>
              <td>{c.kind}</td>
              <td>
                <Form
                  operation="category"
                  hidden={{ id: c.id, active: String(!c.active) }}
                  fields={[]}
                  back="/app/settings"
                  button={c.active ? "Archivar" : "Reactivar"}
                />
              </td>
            </tr>
          ))}
        </Table>
        <details>
          <summary>Agregar categoría</summary>
          <Form
            operation="category"
            fields={[
              { name: "name", label: "Nombre", required: true },
              {
                name: "kind",
                label: "Tipo",
                required: true,
                options: ["income", "expense", "asset"].map((value) => ({
                  value,
                  label: value,
                })),
              },
            ]}
            back="/app/settings"
          />
        </details>
      </Panel>
      <Panel title="Registro de notificaciones">
        <p className="muted">
          Sent indica que Gmail aceptó el correo; no confirma que el cliente lo haya leído. Los envíos fallidos o sin confirmar requieren revisión antes de reenviar.
        </p>
        {role==="admin" && <details><summary>Reintentar un aviso específico</summary><Form operation="retry-notification" fields={[{name:"id",label:"ID de notificación",required:true}]} button="Autorizar reintento" back="/app/settings"><label className="checkbox"><input type="checkbox" name="reconciled" required/>Revisé el destinatario y Enviados en Gmail; autorizo este envío real sin duplicarlo.</label></Form></details>}
        {notifications.length ? (
          <Table headers={["Evento", "Estado", "Programado", "Entrega"]}>
            {notifications.map((n) => (
              <tr key={n.id}>
                <td>{n.event}<small style={{display:"block"}}>{n.id}</small></td>
                <td>{n.status}</td>
                <td>{new Date(n.due_at).toLocaleString("es-US")}</td>
                <td>{n.mail_error || n.provider_id || "Pendiente"}</td>
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
