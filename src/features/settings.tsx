import {SettingsDisclosure} from "@/components/settings-disclosure";
import {SettingsSection} from "@/components/settings-section";
import Link from "next/link";
import {DEFAULT_TAX_QUARTERS} from "@/lib/domain/sales-tax-summary";
import {QuarterSettings} from "@/components/quarter-settings";
import {isPresentationTest} from "@/lib/domain/presentation";
import {RolesSettings} from "@/components/roles-settings";
import {requireOwner,rows} from "@/lib/domain/context";
import {SmsSettings} from "@/components/sms-settings";
import {denverDateTime} from "@/lib/domain/time";
import {Heading,Table} from "@/components/ui";
import {Form} from "@/components/form";
const TABS=[["general","General"],["pick-return","Pick & Return"],["prices","Prices & Taxes"],["notifications","Notifications"],["users","Users & Roles"]] as const;
export async function Settings({tab}:{tab?:string}){
 const owner=await requireOwner();
 const active=TABS.some(([key])=>key===tab)?tab!:"general";
 const heading=<><Heading title="Settings" subtitle="Business and workspace configuration"><Link className="button menu-link-gold" href="/app/reference">Reference / About</Link></Heading><nav className="settings-tabs main-tab-list" aria-label="Settings sections">{TABS.map(([key,label])=><Link key={key} href={`/app/settings?tab=${key}`} className={`main-tab ${active===key?"active":""}`} aria-current={active===key?"page":undefined}>{label}</Link>)}</nav></>;
 if(active==="users"){const {data,error}=await owner.db.rpc("rbac_directory");if(error||!data)throw new Error("Could not load users and roles.");return <>{heading}<RolesSettings directory={data}/></>;}
 const s=(await rows("unit_settings"))[0];
if(active==="general"){const [policies,categories]=await Promise.all([rows("policies",{order:"version"}),rows("categories")]);return <>{heading}<div className="settings-card-grid"><SettingsSection title="Business / Workspace" summary={`${s?.business_display_name || "ToolTag"} · ${s?.timezone || "America/Denver"}`}>
        <p className="muted">Workspace contact details only. These fields do not replace your Gmail aliases, payment accounts or accepted documents.</p>
        <Form operation="workspace-profile" fields={[
          { name: "business_display_name", label: "Business Display Name", value: s?.business_display_name ?? "" },
          { name: "business_contact_email", label: "Business Contact Email", type: "email", value: s?.business_contact_email ?? "" },
          { name: "business_contact_phone", label: "Business Contact Phone", type: "tel", value: s?.business_contact_phone ?? "" },
        ]} back="/app/settings?tab=general" button="Save Business Details" />


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

      <p className="muted">This address is shown to the driver as a departure reference. Approximate ETA still uses the driver&apos;s live location; saving it does not reschedule stops.</p>
      <Form operation="workspace-profile" fields={[{ name: "route_departure_address", label: "Shop / Route Departure Address", type: "textarea", wide: true, value: s?.route_departure_address ?? "" }]} back="/app/settings?tab=general" button="Save Departure Point" />
    </SettingsSection>
<SettingsSection title="Agreements / Policies">
        <p className="notice">
          Publish only approved policy text.
          Each version is preserved; previous acceptances retain
          their exact accepted content.
        </p>
        {policies.map((p) => (
          <details key={p.id}>
            <summary>
              {p.title} · Version {String(p.version).replace(/^v(?:ersion)?\s*/i, "")}
            </summary>
            <div className="policy">{p.content}</div>
          </details>
        ))}
        <SettingsDisclosure title="Publish a New Approved Version">
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
        </SettingsDisclosure>
      </SettingsSection>
<SettingsSection title="Categories">
        <Table headers={["Name", "Type", "Status", "Action"]}>
          {categories.map((c) => (
            <tr key={c.id}>
              <td>{c.name}</td>
              <td>{c.kind}</td>
              <td><span className="badge">{c.active ? "Active" : "Archived"}</span></td>
              <td>
                <Form inlineActions
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
        <SettingsDisclosure title="Add Category">
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
        </SettingsDisclosure>
      </SettingsSection>
</div></>; }
if(active==="pick-return")return <>{heading}<div className="settings-card-grid"><SettingsSection title="Pick & Return" summary="Pickup 8 AM–12 PM · Delivery 2–6 PM · Denver time">
      <p className="notice">If you change or add Pickup or Delivery days, review the Customer Agreement and update it as needed before offering the new schedule. ToolTag does not edit or republish the Agreement automatically.</p>
      <p className="muted">Select at least one day for each route. Existing bookings stay unchanged.</p><Form operation="settings" hidden={{ pickup_route_iso_weekdays_present: "1", return_route_iso_weekdays_present: "1" }} fields={[
        ...(["pickup", "return"] as const).map(leg => ({ name: `${leg}_route_iso_weekdays`, label: leg === "pickup" ? "Pickup Route Days" : "Delivery Route Days", value: (s?.[`${leg}_route_iso_weekdays`] ?? [leg === "pickup" ? 6 : (s?.delivery_route_iso_weekday ?? 7)]).join(","), multiple: true, options: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].map((label, index) => ({ value: String(index + 1), label })) })),
        { name: "max_delivery_stops_per_sunday", label: "Maximum Stops per Delivery Route Day", type: "number", value: String(s?.max_delivery_stops_per_sunday ?? 20), help: "13 reservable ETAs; multiple delivery stops may share an ETA." },
        { name: "max_pickup_stops_per_saturday", label: "Maximum Stops per Pickup Route Day", type: "number", required: true, value: String(s?.max_pickup_stops_per_saturday ?? 10), help: "Review & Accept hides Pickup days once this capacity is reached." },
      ]} back="/app/settings?tab=pick-return" button="Save Route Settings" />
    <h3>Route windows</h3><p>Pickup · 8:00 AM–12:00 PM</p><p>Delivery · 2:00 PM–6:00 PM</p><p className="muted">Denver time · fixed windows</p><h3>Delivery retry</h3><Form operation="settings" fields={[{name:"second_delivery_attempt_fee",label:"Second Delivery Attempt Fee (USD)",type:"number",value:String(s?.second_delivery_attempt_fee ?? 10)}]} back="/app/settings?tab=pick-return" button="Save Retry Fee" /></SettingsSection>
</div></>;
if(active==="notifications"){const [mailResult,sms,accounts]=await Promise.all([owner.db.rpc("customer_mail_status"),owner.db.rpc("sms_settings_status"),rows("accounts")]);const mail=mailResult.data;return <>{heading}<div className="settings-card-grid"><SettingsSection title="Notifications & Messaging" summary={`Email and SMS · $${Number(s?.sms_unit_cost ?? 0.00645).toFixed(5)} per accepted SMS`}><SmsSettings info={sms.data ?? {}} mode={process.env.TOOLTAG_SMS_MODE || "preview"} envConfigured={Boolean(process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY)} envRegion={process.env.AWS_REGION || ""} envOrigin={process.env.TOOLTAG_SMS_ORIGINATION_NUMBER || ""} envTestPhone={process.env.TOOLTAG_SMS_TEST_PHONE || ""} encryptionReady={Boolean(process.env.TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY)} /><h3>SMS cost accounting</h3><Form operation="sms-cost-settings" fields={[{name:"sms_unit_cost",label:"Cost per AWS-accepted SMS (USD)",type:"number",step:"0.00000001",required:true,value:Number(s?.sms_unit_cost??0.00645).toFixed(5),help:"Each AWS-accepted send keeps its rate, including later delivery failures. Rejected/unsent requests have no accepted-send cost."},{name:"sms_expense_account_id",label:"SMS expense account",required:true,value:s?.sms_expense_account_id??"",options:accounts.filter(a=>a.active && (!isPresentationTest(a.name)||a.id===s?.sms_expense_account_id)).map(a=>({value:a.id,label:isPresentationTest(a.name)?"Current account":a.name}))}]} back="/app/settings?tab=notifications" button="Save SMS Cost"/><Link href="/app/finance/sms">View SMS costs</Link><h3>Customer email</h3>
        <p>Email mode: {process.env.TOOLTAG_MAIL_MODE || "preview"}</p>
        <p>Eligible notifications start: {denverDateTime(mail?.activated_at)}</p>
        <p>Activation does not resend tests or historical notifications. Failures require an individual retry.</p>
        {!mail?.activated_at && <Form operation="activate-live-mail" fields={[]} button="Enable New Notifications" back="/app/settings?tab=notifications"><label className="checkbox"><input type="checkbox" name="confirm" required/>Enable only new notifications from this point forward.</label></Form>}

      <Link className="button menu-link-gold" href="/app/support/monitoring">Delivery monitoring</Link></SettingsSection>
</div></>; }
return <>{heading}<div className="settings-card-grid"><SettingsSection title="Taxes & Fees" summary={`Utah sales tax · ${Number(s?.sales_tax_rate ?? 7.45).toFixed(2)}%`}><Form operation="sales-tax-settings" fields={[{name:"sales_tax_rate",label:"Sales Tax Rate (%)",type:"number",step:"0.001",required:true,value:Number(s?.sales_tax_rate ?? 7.45).toFixed(2),help:"Applied to the service subtotal, including logistics fees. Existing sent and accepted quotes retain their stored rate."}]} back="/app/settings?tab=prices" button="Save Tax Rate" /><h3>Reporting year</h3><QuarterSettings starts={s?.sales_tax_quarter_starts ?? DEFAULT_TAX_QUARTERS}/><p><Link href="/app/reference#logistics">View current logistics fees</Link></p></SettingsSection>
<SettingsSection title="Payments">

      <p>Card provider: <strong>{process.env.STRIPE_SECRET_KEY && process.env.STRIPE_WEBHOOK_SECRET ? "Stripe configured" : "Stripe not configured"}</strong></p>
      <p>Logistics fees are prepaid electronically. Cash is available only for an eligible in-person final balance.</p>
      <Form operation="settings" fields={[
        { name: "zelle_email", label: "ToolTag Zelle identifier", value: s?.zelle_email ?? "", help: "Use the confirmed ToolTag payment account, never a customer account." },
        { name: "venmo_handle", label: "ToolTag Venmo handle", value: s?.venmo_handle ?? "", help: "Confirmed account: @boftbuild (Bandits of the Framing)." },
      ]} back="/app/settings?tab=prices" button="Save Payment Settings" />
    </SettingsSection>
</div></>;
}
