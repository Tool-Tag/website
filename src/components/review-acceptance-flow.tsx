"use client";
import {salesTax} from "@/lib/domain/sales-tax";
import {TaxBreakdown} from "./tax-breakdown";

import { useActionState, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { customerAction, type ActionState } from "@/app/actions";
import { SmsConsentFields } from "@/components/sms-consent";
import { Panel } from "@/components/ui";
import { QuoteScope } from "@/components/quote-scope";
import { money } from "@/lib/domain/money";
import {
  LOGISTICS_OPTIONS,
  logisticsOption,
  type LogisticsOptionCode,
} from "@/lib/domain/logistics";
import type { QuoteItem } from "@/lib/domain/quote-items";

type SaturdayOption = {
  date: string;
  remaining: number;
  window: string;
};

export type ReviewLogisticsContext = {
  requires_selection?: boolean;
  predefined?: boolean;
  selected_option?: LogisticsOptionCode | null;
  personal_address?: string | null;
  company_address?: string | null;
  extra_addresses?: string[];
  pickup_address?: string | null;
  delivery_address?: string | null;
  saturday_date?: string | null;
  available_saturdays?: SaturdayOption[];
  locked?: boolean;
};

function AddressField({
  label,
  personal,
  company,
  value,
  onChange,
  extra=[],save=false,onSave,
}: {
  label: string;
  personal?: string | null;
  company?: string | null;
  value: string;
  onChange: (value: string) => void;
  extra?:string[];save?:boolean;onSave?:(value:boolean)=>void;
}) {
  const saved = useMemo(
    () =>
      [
        personal
          ? { value: "personal", label: "Personal address", address: personal }
          : null,
        company
          ? { value: "company", label: "Company address", address: company }
          : null,
        ...extra.map((address,index)=>({value:`extra-${index}`,label:`Saved address ${index+1}`,address})),
      ].filter(Boolean) as { value: string; label: string; address: string }[],
    [personal, company, extra],
  );

  const [selected, setSelected] = useState(() => saved.find(entry => entry.address === value)?.value ?? (value ? "new" : saved[0]?.value ?? "new"));
  useEffect(() => {
    if (selected !== "new" && !value) {
      const address = saved.find(entry => entry.value === selected)?.address;
      if (address) onChange(address);
    }
  }, [selected, value, saved, onChange]);

  return (
    <div className="logistics-address">
      <label>
        {label}
        {saved.length > 0 && (
          <select
            value={selected}
            onChange={(event) => {
              const next = event.target.value;
              setSelected(next);
              const found = saved.find((entry) => entry.value === next);
              onChange(found?.address ?? "");
            }}
          >
            {saved.map((entry) => (
              <option value={entry.value} key={entry.value}>
                {entry.label}
              </option>
            ))}
            <option value="new">Enter a different address</option>
          </select>
        )}
      </label>
      {(selected === "new" || saved.length === 0) && (
        <label>
          Street address, city, state and ZIP
          <textarea
            required
            maxLength={500}
            rows={2}
            autoComplete="street-address"
            value={value}
            onChange={(event) => onChange(event.target.value)}
          />
        </label>
      )}
      {selected==="new"&&value.trim()&&onSave&&<label className="checkbox"><input type="checkbox" checked={save} onChange={event=>onSave(event.target.checked)}/>Add this address to my saved address list</label>}
      {selected !== "new" && value && <p className="muted">{value}</p>}
    </div>
  );
}

export function ReviewAcceptanceFlow({
  token,
  items,
  baseTotal,
  notes,
  policy,
  logistics,
  smsConsent,
  taxRate="0",
}: {
  token: string;
  items: QuoteItem[];
  baseTotal: number | string;
  taxRate?: string;
  notes?: string | null;
  policy: { title: string; version: number | string; content: string };
  logistics: ReviewLogisticsContext;
  smsConsent?: { phone?: string; granted?: boolean };
}) {
  const router = useRouter();
  const predefined = Boolean(logistics.predefined);
  const [optionCode, setOptionCode] = useState<LogisticsOptionCode | "">(
    (logistics.selected_option as LogisticsOptionCode | null) ?? "",
  );
  const selected = logisticsOption(optionCode);
  const [pickupAddress, setPickupAddress] = useState(
    logistics.pickup_address ??
      logistics.personal_address ??
      logistics.company_address ??
      "",
  );
  const [deliveryAddress, setDeliveryAddress] = useState(
    logistics.delivery_address ?? "",
  );
  const [sameAsPickup, setSameAsPickup] = useState(
    optionCode === "pickup_delivery" && !logistics.delivery_address,
  );
  const [saturdayDate, setSaturdayDate] = useState(
    logistics.saturday_date ?? "",
  );
  const [savePickup,setSavePickup]=useState(false);const [saveDelivery,setSaveDelivery]=useState(false);
  const [quoteConfirmed, setQuoteConfirmed] = useState(false);
  const [agreementConfirmed, setAgreementConfirmed] = useState(false);
  const [state, action, pending] = useActionState<ActionState, FormData>(
    customerAction.bind(null, "review", token),
    {},
  );

  useEffect(() => {
    if (state.link) {
      router.push(state.link);
    } else if (state.ok) {
      router.refresh();
    }
  }, [state.link, state.ok, router]);

  const total = useMemo(
    () => Number(baseTotal || 0) + (selected?.fee ?? 0),
    [baseTotal, selected],
  );

  const effectiveDeliveryAddress =
    optionCode === "pickup_delivery" && sameAsPickup
      ? pickupAddress
      : deliveryAddress;

  const logisticsValid = Boolean(
    selected &&
      (!selected.pickup || (pickupAddress.trim() && saturdayDate)) &&
      (!selected.delivery || effectiveDeliveryAddress.trim()),
  );
  const canAccept =
    logisticsValid && quoteConfirmed && agreementConfirmed && !pending && !state.ok;

  const payload = JSON.stringify({
    option_code: optionCode || null,
    save_pickup_address:selected?.pickup&&savePickup,
    save_delivery_address:selected?.delivery&&(selected?.pickup&&sameAsPickup?savePickup:saveDelivery),
    pickup_address: selected?.pickup ? pickupAddress.trim() : null,
    delivery_address: selected?.delivery
      ? effectiveDeliveryAddress.trim()
      : null,
    saturday_date: selected?.pickup ? saturdayDate : null,
  });

  return (
    <>
      <Panel title="Complete quote">
        <QuoteScope items={items} />
        {selected && (
          <div className="logistics-total-line">
            <span>Logistics — {selected.name}</span>
            <strong>{selected.fee ? money(selected.fee) : "Free"}</strong>
          </div>
        )}
        <TaxBreakdown pricing={salesTax(total.toFixed(2),taxRate)} />
        {notes && <p>{notes}</p>}
      </Panel>

      <Panel title="Logistics — how should we handle your items?">
        <p className="muted">Required — choose one.</p>

        {predefined && selected ? (
          <div className="logistics-readonly">
            <strong>{selected.name}</strong>
            <span>{selected.fee ? money(selected.fee) : "Free"}</span>
            <p>{selected.description}</p>
            <small>This logistics method was already defined on your Quote.</small>
          </div>
        ) : (
          <div
            className="logistics-options"
            role="radiogroup"
            aria-label="Logistics option"
          >
            {LOGISTICS_OPTIONS.map((option) => (
              <label
                className={
                  optionCode === option.code
                    ? "logistics-option selected"
                    : "logistics-option"
                }
                key={option.code}
              >
                <input
                  type="radio"
                  name="logistics_option_preview"
                  value={option.code}
                  checked={optionCode === option.code}
                  onChange={() => {
                    setOptionCode(option.code);
                    if (option.code === "pickup_delivery") setSameAsPickup(true);
                  }}
                />
                <span>
                  <strong>{option.name}</strong>
                  <small>{option.fee ? money(option.fee) : "Free"}</small>
                  <p>{option.description}</p>
                </span>
              </label>
            ))}
          </div>
        )}

        {selected && (
          <div className="logistics-selected-detail">
            <strong>{selected.name}</strong>
            <p>{selected.description}</p>
            <p>
              Logistics charge:{" "}
              <strong>{selected.fee ? money(selected.fee) : "Free"}</strong>
            </p>
          </div>
        )}

        {selected?.pickup && (
          <>
            <AddressField
              label="Pickup address"
              personal={logistics.personal_address}
              company={logistics.company_address}
              value={pickupAddress}
              onChange={setPickupAddress}
              extra={logistics.extra_addresses} save={savePickup} onSave={setSavePickup}
            />
            <label>
              Requested Pickup date
              <select
                required
                value={saturdayDate}
                onChange={(event) => setSaturdayDate(event.target.value)}
              >
                <option value="">Choose an available Pickup date…</option>
                {(logistics.available_saturdays ?? []).map((day) => (
                  <option key={day.date} value={day.date}>
                    {new Date(day.date + "T12:00:00").toLocaleDateString(
                      "en-US",
                      {
                        weekday: "long",
                        month: "short",
                        day: "numeric",
                        year: "numeric",
                      },
                    )}{" "}
                    · 8:00 AM–12:00 PM · {day.remaining} spot
                    {day.remaining === 1 ? "" : "s"} left
                  </option>
                ))}
              </select>
            </label>
            {!(logistics.available_saturdays ?? []).length && (
              <p className="notice error">
                No Pickup capacity is currently available. Contact
                ToolTag before accepting.
              </p>
            )}
            <p className="muted">
              Pickup window: 8:00 AM–12:00 PM. On route day, your ETA is sent by
              notification based on route order.
            </p>
          </>
        )}

        {selected?.delivery && (
          <>
            {selected.pickup && (
              <label className="checkbox">
                <input
                  type="checkbox"
                  checked={sameAsPickup}
                  onChange={(event) => {
                    setSameAsPickup(event.target.checked);
                  }}
                />
                Delivery address is the same as the Pickup address.
              </label>
            )}
            {!selected.pickup || !sameAsPickup ? (
              <AddressField
                label="Delivery address"
                personal={logistics.personal_address}
                company={logistics.company_address}
                value={deliveryAddress}
                onChange={setDeliveryAddress}
                extra={logistics.extra_addresses} save={saveDelivery} onSave={setSaveDelivery}
              />
            ) : (
              <p className="muted">Delivery address: {pickupAddress}</p>
            )}
            {!selected.pickup && (
              <p className="muted">
                Delivery day and time are coordinated after the work is
                finished.
              </p>
            )}
          </>
        )}
      </Panel>

      <Panel title="Terms & Customer Agreement">
        <h3>
          {policy.title} · Version {policy.version}
        </h3>
        <div className="policy">{policy.content}</div>
      </Panel>

      <Panel title="Review & Accept">
        <p>
          Please check spelling, designs, locations, quantities, colors and your
          logistics selection. Contact ToolTag before accepting if anything
          needs to change.
        </p>
        <form action={action} className="stack">
          <input type="hidden" name="logistics" value={payload} />
          <SmsConsentFields phone={smsConsent?.phone} granted={smsConsent?.granted} />
          <label className="checkbox">
            <input
              type="checkbox"
              name="quote_confirmed"
              required
              checked={quoteConfirmed}
              onChange={(event) => setQuoteConfirmed(event.target.checked)}
            />
            I have reviewed and approve the quote details.
          </label>
          <label className="checkbox">
            <input
              type="checkbox"
              name="agreement_confirmed"
              required
              checked={agreementConfirmed}
              onChange={(event) => setAgreementConfirmed(event.target.checked)}
            />
            I have read and agree to ToolTag’s Terms &amp; Conditions.
          </label>
          {state.error && (
            <p role="alert" className="notice error">
              {state.error}
            </p>
          )}
          <button disabled={!canAccept}>
            {pending ? "Saving…" : "Accept Quote & Agreement"}
          </button>
        </form>
      </Panel>
    </>
  );
}
