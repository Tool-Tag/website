import Link from "next/link";
import {DEFAULT_TAX_QUARTERS} from "@/lib/domain/sales-tax-summary";
import { RolesSettings } from "@/components/roles-settings";
import { requireOwner, rows } from "@/lib/domain/context";
import { SmsSettings } from "@/components/sms-settings";
import { denverDateTime } from "@/lib/domain/time";
import { LOGISTICS_OPTIONS } from "@/lib/domain/logistics";
import { money } from "@/lib/domain/money";
import { Heading, Panel, Table, Empty } from "@/components/ui";
import { Form } from "@/components/form";

const TABS = [
  ["general", "General"],
  ["pick-return", "Pick up & Delivery"],
  ["notifications", "Notifications"],
  ["prices", "Prices"],
  ["users", "Users and roles"],
] as const;

export async function Settings({ tab }: { tab?: string }) {
  const owner = await requireOwner();
  const active = TABS.some(([key]) => key === tab) ? tab! : "general";
  const tabs = <nav className="settings-tabs" aria-label="Settings sections">{TABS.map(([key, label]) => <Link key={key} href={`/app/settings?tab=${key}`} className={`button ${active === key ? "" : "secondary"}`} aria-current={active === key ? "page" : undefined}>{label}</Link>)}</nav>;
  const heading = <><Heading title="Settings" subtitle="ToolTag · Bandits of the Framing LLC" />{tabs}</>;
  if (active === "users") {
    const { data, error } = await owner.db.rpc("rbac_directory");
    if (error || !data) throw new Error("Could not load users and roles.");
    return <>{heading}<RolesSettings directory={data} /></>;
  }
  const settings = await rows("unit_settings");
  const s = settings[0];
  if (active === "general") {
    const [policies, categories] = await Promise.all([rows("policies", { order: "version" }), rows("categories")]);
    return <>{heading}
      <Panel title="Business Contact Details">
        <p className="muted">Workspace contact details only. These fields do not replace your Gmail aliases, payment accounts or accepted documents.</p>
        <Form operation="workspace-profile" fields={[
          { name: "business_display_name", label: "Business Display Name", value: s?.business_display_name ?? "" },
          { name: "business_contact_email", label: "Business Contact Email", type: "email", value: s?.business_contact_email ?? "" },
          { name: "business_contact_phone", label: "Business Contact Phone", type: "tel", value: s?.business_contact_phone ?? "" },
        ]} back="/app/settings?tab=general" button="Save Business Details" />
      </Panel>
<Panel title="Workspace">
          <p className="muted">
            Private binary files are stored in Supabase Storage. Google Drive is
            reserved for a future backup-only synchronization process and is not
            written by this app.
          </p>
          <Form
            operation="settings"
            fields={[
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
            back="/app/settings?tab=general"
          />
        </Panel>
<Panel title="Agreements / Policies">
        <p className="notice">
          No legal text has been invented. Publish only approved text.
          Each version is preserved; previous acceptances retain
          their exact accepted content.
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
            back="/app/settings?tab=general"
            button="Publish Version"
          />
        </details>
      </Panel>
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
                  back="/app/settings?tab=general"
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
            back="/app/settings?tab=general"
          />
        </details>
      </Panel>
<Panel title="Current Rules"><p>Quote: 7 days · reminder: 2 days before expiration.</p><p>Refund review: 14 days.</p><p>Delivery acceptance: 3 days after notification.</p><p>Monthly close: day 1, previous month.</p></Panel>
</>;
  }
  if (active === "notifications") {
    const [mailResult, sms, notifications] = await Promise.all([owner.db.rpc("customer_mail_status"), owner.db.rpc("sms_settings_status"), rows("notifications", { order: "created_at", limit: 30 })]);
    const accounts=await rows("accounts");
    const mail = mailResult.data;
    return <>{heading}
      <SmsSettings info={sms.data ?? {}} mode={process.env.TOOLTAG_SMS_MODE || "preview"} envConfigured={Boolean(process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY)} envRegion={process.env.AWS_REGION || ""} envOrigin={process.env.TOOLTAG_SMS_ORIGINATION_NUMBER || ""} envTestPhone={process.env.TOOLTAG_SMS_TEST_PHONE || ""} encryptionReady={Boolean(process.env.TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY)} />
<Panel title="SMS cost accounting"><Form operation="sms-cost-settings" fields={[{name:"sms_unit_cost",label:"Cost per AWS-accepted SMS (USD)",type:"number",step:"0.00000001",required:true,value:String(s?.sms_unit_cost??0.00645),help:"Each AWS-accepted send keeps its rate, including later delivery failures. Rejected/unsent requests have no accepted-send cost."},{name:"sms_expense_account_id",label:"SMS expense account",required:true,value:s?.sms_expense_account_id??"",options:accounts.filter(a=>a.active).map(a=>({value:a.id,label:a.name}))}]} back="/app/settings?tab=notifications" button="Save SMS Cost"/><p>Costs follow the Quote into its Job. They post under SMS when the Job completes or an unconverted Quote expires/is deleted. Amounts round once on the cumulative cost.</p><Link href="/app/finance/sms">View SMS costs</Link></Panel>
<Panel title="Production Email">
        <p>Server mode: {process.env.TOOLTAG_MAIL_MODE || "preview"}</p>
        <p>Eligible notifications start: {denverDateTime(mail?.activated_at)}</p>
        <p>Activation does not resend tests or historical notifications. Failures require an individual retry.</p>
        {!mail?.activated_at && <Form operation="activate-live-mail" fields={[]} button="Enable New Notifications" back="/app/settings?tab=notifications"><label className="checkbox"><input type="checkbox" name="confirm" required/>Enable only new notifications from this point forward.</label></Form>}
        <p className="muted">To deliver to customers, Vercel must have TOOLTAG_MAIL_MODE=live. This screen does not modify Vercel environment variables.</p>
      </Panel>
<Panel title="Notification Log">
        <p className="muted">
          Sent means Gmail accepted the email for delivery; it does not confirm that the customer read it. Failed or unconfirmed deliveries require review before resending.
        </p>
        {<details><summary>Retry a Specific Notification</summary><Form operation="retry-notification" fields={[{name:"id",label:"Notification ID",required:true}]} button="Authorize Retry" back="/app/settings?tab=notifications"><label className="checkbox"><input type="checkbox" name="reconciled" required/>I reviewed the recipient and Gmail Sent folder; I authorize this real resend without duplicating it.</label></Form></details>}
        {notifications.length ? (
          <Table headers={["Event", "Status", "Scheduled", "Delivery"]}>
            {notifications.map((n) => (
              <tr key={n.id}>
                <td>{n.event}<small style={{display:"block"}}>{n.id}</small></td>
                <td>{n.status}</td>
                <td>{denverDateTime(n.due_at)}</td>
                <td>{n.mail_error || n.provider_id || "Pending"}</td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty />
        )}
      </Panel>
<Panel title="Support / Hello inbox"><p>Read and respond in the Notifications inbox. Gmail inbox access is configured separately from automatic customer notification delivery.</p><Link className="button secondary" href="/app/notifications">Open inbox</Link></Panel>
</>;
  }
  if (active === "pick-return") return <>{heading}
    <Panel title="Route Days and Capacity">
      <p className="notice">If you change or add Pickup or Delivery days, review the Customer Agreement and update it as needed before offering the new schedule. ToolTag does not edit or republish the Agreement automatically.</p>
      <Form operation="settings" hidden={{ pickup_route_iso_weekdays_present: "1", return_route_iso_weekdays_present: "1" }} fields={[
        ...(["pickup", "return"] as const).map(leg => ({ name: `${leg}_route_iso_weekdays`, label: leg === "pickup" ? "Pickup Route Days" : "Delivery Route Days", value: (s?.[`${leg}_route_iso_weekdays`] ?? [leg === "pickup" ? 6 : (s?.delivery_route_iso_weekday ?? 7)]).join(","), multiple: true, options: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].map((label, index) => ({ value: String(index + 1), label })), help: "Select at least one day. New availability updates automatically; existing bookings stay unchanged." })),
        { name: "max_delivery_stops_per_sunday", label: "Maximum Stops per Delivery Route Day", type: "number", value: String(s?.max_delivery_stops_per_sunday ?? 20), help: "13 reservable ETAs; multiple delivery stops may share an ETA." },
        { name: "max_pickup_stops_per_saturday", label: "Maximum Stops per Pickup Route Day", type: "number", required: true, value: String(s?.max_pickup_stops_per_saturday ?? 10), help: "Review & Accept hides Pickup days once this capacity is reached." },
      ]} back="/app/settings?tab=pick-return" button="Save Route Settings" />
    </Panel>
    <Panel title="Route Departure Point">
      <p className="muted">This address is shown to the driver as a departure reference. Approximate ETA still uses the driver&apos;s live location; saving it does not reschedule stops.</p>
      <Form operation="workspace-profile" fields={[{ name: "route_departure_address", label: "Shop / Route Departure Address", type: "textarea", wide: true, value: s?.route_departure_address ?? "" }]} back="/app/settings?tab=pick-return" button="Save Departure Point" />
    </Panel>
    <Panel title="Route Windows"><p>Pickup: 8:00 AM–12:00 PM · America/Denver.</p><p>Delivery: 2:00 PM–6:00 PM · America/Denver.</p><p className="muted">These are the current fixed scheduling windows. Changing route days preserves these windows and existing bookings.</p></Panel>
  </>;
  return <>{heading}
    <Panel title="Engraving Pricing"><p>Base service price is reviewed manually for each quote item.</p><p>The first engraving is included; each additional engraving costs $5 per physical piece.</p><p>Paint fill costs $2 per colored physical piece, once per piece.</p><p>Falcon image/logo preparation costs $3 per unique image/logo, once per quote.</p><p className="muted">These are the existing pricing rules. This page does not change accepted quote snapshots or pricing calculations.</p></Panel>
    <Panel title="Utah Sales Tax"><Form operation="sales-tax-settings" fields={[{name:"sales_tax_rate",label:"Sales Tax Rate (%)",type:"number",step:"0.001",required:true,value:String(s?.sales_tax_rate ?? 7.45),help:"Applied to the service subtotal, including logistics fees. Existing sent and accepted quotes retain their stored rate."}]} back="/app/settings?tab=prices" button="Save Tax Rate" /></Panel>
    <Panel title="Sales Tax Reporting Quarters">
      <p>Set the annual start date for each quarter. Each quarter ends the day before the next one starts, with no gaps or overlaps. Dates repeat every year in Denver time.</p>
      <p className="muted">This changes the Sales Tax reporting periods only. It does not change tax rates, transactions, accepted quotes or the accumulated total. February 29 is unavailable as an annual boundary.</p>
      <Form operation="sales-tax-quarter-settings" fields={(s?.sales_tax_quarter_starts ?? DEFAULT_TAX_QUARTERS).flatMap((date:string,index:number) => [
        {name:`q${index+1}_month`,label:`Q${index+1} start month`,required:true,value:date.slice(0,2),options:Array.from({length:12},(_,i)=>({value:String(i+1).padStart(2,"0"),label:new Intl.DateTimeFormat("en-US",{month:"long",timeZone:"UTC"}).format(new Date(Date.UTC(2001,i,1)))}))},
        {name:`q${index+1}_day`,label:`Q${index+1} start day`,required:true,value:date.slice(3),options:Array.from({length:31},(_,i)=>({value:String(i+1).padStart(2,"0"),label:String(i+1)}))},
      ])} back="/app/settings?tab=prices" button="Save Quarter Dates" />
    </Panel>
    <Panel title="Logistics Fees"><Table headers={["Service", "Fee"]}>{LOGISTICS_OPTIONS.map(option => <tr key={option.code}><td>{option.name}</td><td>{money(option.fee.toFixed(2))}</td></tr>)}</Table></Panel>
    <Panel title="Payment Accounts and Delivery Retry">
      <p className="muted">Identifiers belong to ToolTag. Confirmed Venmo: @boftbuild — Bandits of the Framing.</p>
      <p>Card provider: <strong>{process.env.STRIPE_SECRET_KEY && process.env.STRIPE_WEBHOOK_SECRET ? "Stripe configured" : "Stripe not configured"}</strong></p>
      <p>Final in-person payments: Cash, Zelle, Venmo. Review logistics fees: Card, Zelle or Venmo only · no cash.</p>
      <Form operation="settings" fields={[
        { name: "zelle_email", label: "ToolTag Zelle identifier", value: s?.zelle_email ?? "", help: "Use the confirmed ToolTag payment account, never a customer account." },
        { name: "venmo_handle", label: "ToolTag Venmo handle", value: s?.venmo_handle ?? "", help: "Confirmed account: @boftbuild (Bandits of the Framing)." },
        { name: "second_delivery_attempt_fee", label: "Second Delivery Attempt Fee (USD)", type: "number", value: String(s?.second_delivery_attempt_fee ?? 10) },
      ]} back="/app/settings?tab=prices" button="Save Payment Settings" />
    </Panel>
  </>;
}
