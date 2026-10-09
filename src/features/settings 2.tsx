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
        title="Settings"
        subtitle="ToolTag · Bandits of the Framing LLC"
      />
      <Panel title="Production Email">
        <p>Modo del servidor: {process.env.TOOLTAG_MAIL_MODE || "preview"}</p>
        <p>Eligible notifications start: {mail?.activated_at || "Pending Activation"}</p>
        <p>Activation does not resend tests or historical notifications. Failures require an individual retry.</p>
        {role==="admin" && !mail?.activated_at && <Form operation="activate-live-mail" fields={[]} button="Enable New Notifications" back="/app/settings"><label className="checkbox"><input type="checkbox" name="confirm" required/>Enable only new notifications from this point forward.</label></Form>}
        <p className="muted">To deliver to customers, Vercel must have TOOLTAG_MAIL_MODE=live. This screen does not modify Vercel environment variables.</p>
      </Panel>
      <Panel title="Google Drive"><p>UI prepared · configuration pending. Uploads and previews are disabled.</p><pre style={{whiteSpace:"pre-wrap"}}>ToolTag Customers / Customer / Jobs / Job / Agreement, Receiving, Completed, Payments, Issue-Review, Other</pre></Panel>
      <Panel title="Agreements / Policies">
        <p className="notice">
          No legal text has been invented. Publish only approved text.
          Each version is preserved; previous acceptances retain
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
          <summary>Publish a New Approved Version</summary>
          <Form
            operation="publish-policy"
            fields={[
              { name: "title", label: "Title", required: true },
              {
                name: "content",
                label: "Exact Approved Text (English)",
                type: "textarea",
                required: true,
                wide: true,
              },
            ]}
            back="/app/settings"
            button="Publish Version"
          />
        </details>
      </Panel>
      <div className="grid two">
        <Panel title="Current Rules">
          <p>Quote: 7 days · Reminder: 2 days before expiration.</p>
          <p>Refund review: 14 days.</p>
          <p>Delivery acceptance: 3 days after notification.</p>
          <p>Monthly close: day 1, previous month.</p>
          <p>Payments: Cash, Zelle, Venmo.</p>
        </Panel>
        <Panel title="Documents / Drive">
          <p className="muted">
            Upload integration pending. You can link real files
            that already exist by their Drive File ID.
          </p>
          <Form
            operation="settings"
            fields={[
              {
                name: "drive_root_id",
                label: "ToolTag Customers Root Folder",
                value: s?.drive_root_id ?? "",
              },
              {
                name: "timezone",
                label: "Time Zone",
                value: s?.timezone ?? "America/Denver",
              },
              {
                name: "boft_url",
                label: "BOFT System URL",
                type: "url",
                value: s?.boft_url ?? "",
              },
              {
                name: "annual_vehicle_method",
                label: "Annual Vehicle Report Method",
                value: s?.annual_vehicle_method ?? "Fuel",
                options: [
                  { value: "Fuel", label: "Fuel" },
                  { value: "Mileage", label: "Travel / Mileage" },
                ],
              },
              {
                name: "mileage_rate",
                label: "Mileage Rate for Analysis (Optional)",
                value: s?.mileage_rate ?? "",
                type: "number",
              },
            ]}
            back="/app/settings"
          />
        </Panel>
      </div>
      <Panel title="Categories">
        <Table headers={["Name", "Type", "Status"]}>
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
                  button={c.active ? "Archive" : "Reactivate"}
                />
              </td>
            </tr>
          ))}
        </Table>
        <details>
          <summary>Add Category</summary>
          <Form
            operation="category"
            fields={[
              { name: "name", label: "Name", required: true },
              {
                name: "kind",
                label: "Type",
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
      <Panel title="Notification Log">
        <p className="muted">
          Sent means Gmail accepted the email for delivery; it does not confirm that the customer read it. Failed or unconfirmed deliveries require review before resending.
        </p>
        {role==="admin" && <details><summary>Retry a Specific Notification</summary><Form operation="retry-notification" fields={[{name:"id",label:"Notification ID",required:true}]} button="Authorize Retry" back="/app/settings"><label className="checkbox"><input type="checkbox" name="reconciled" required/>I reviewed the recipient and Gmail Sent folder; I authorize this real resend without duplicating it.</label></Form></details>}
        {notifications.length ? (
          <Table headers={["Event", "Status", "Scheduled", "Delivery"]}>
            {notifications.map((n) => (
              <tr key={n.id}>
                <td>{n.event}<small style={{display:"block"}}>{n.id}</small></td>
                <td>{n.status}</td>
                <td>{new Date(n.due_at).toLocaleString("en-US")}</td>
                <td>{n.mail_error || n.provider_id || "Pending"}</td>
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
