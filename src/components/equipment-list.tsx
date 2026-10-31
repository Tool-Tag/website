"use client";
import {HexModalFrame} from "./hex-modal-frame";

import {ModalClose} from "./modal-close";

import Link from "next/link";
import {useRouter} from "next/navigation";
import {useEffect, useId, useRef, useState} from "react";
import {AssetForm} from "./asset-form";
import {useActionPermission} from "./permission-provider";
import {Empty, Panel, Table} from "./ui";
import {money} from "@/lib/domain/money";
import {denverDateTime} from "@/lib/domain/time";

type Option = {value: string; label: string};
export type EquipmentRecord = {
  id: string; name: string; category: string; serialNumber: string | null;
  warrantyExpiration: string | null; origin: string; status: string;
  purchaseCost: number | null; estimatedValue: number | null;
  expenseId: string | null; vendor: string | null; purchaseDate: string | null;
  donatedBy: string | null; receivedDate: string | null; notes: string | null;
  createdAt: string;
};

export function EquipmentList({assets, categories, expenses, expense}: {
  assets: EquipmentRecord[]; categories: Option[]; expenses: Option[]; expense?: string;
}) {
  const allowed = useActionPermission("asset");
  const router = useRouter();
  const [registering, setRegistering] = useState(Boolean(expense));
  const [selected, setSelected] = useState<EquipmentRecord | null>(null);
  const registration = useRef<HTMLDialogElement>(null);
  const detail = useRef<HTMLDialogElement>(null);
  const registrationTitle = useId(), detailTitle = useId();
  useEffect(() => {
    if (registering && allowed && !registration.current?.open) registration.current?.showModal();
  }, [registering, allowed]);
  useEffect(() => {
    if (selected && !detail.current?.open) detail.current?.showModal();
  }, [selected]);
  const closeRegistration = () => {registration.current?.close(); setRegistering(false);};
  const closeDetail = () => {detail.current?.close(); setSelected(null);};
  return <>
    {allowed && <div className="actions"><button type="button" className="menu-link-blue-electric" onClick={() => setRegistering(true)}>Register Equipment</button></div>}
    <Panel>{assets.length ? <Table headers={["Equipment Name", "Category", "Serial Number", "Warranty Expiration", "Cost"]}>
      {assets.map(asset => <tr key={asset.id} className="equipment-list-row" tabIndex={0}
        aria-label={`View ${asset.name}`} onClick={() => setSelected(asset)}
        onKeyDown={event => {if (event.target === event.currentTarget && (event.key === "Enter" || event.key === " ")) {event.preventDefault(); setSelected(asset);}}}>
        <td><button className="equipment-name-button" type="button">{asset.name}</button></td>
        <td>{asset.category}</td><td>{asset.serialNumber || "—"}</td>
        <td>{asset.warrantyExpiration || "—"}</td>
        <td>{asset.origin === "Purchased" ? money(asset.purchaseCost ?? 0) : <>{money(asset.estimatedValue ?? 0)} <small>(estimated value)</small></>}</td>
      </tr>)}
    </Table> : <Empty>No equipment registered yet.</Empty>}</Panel>
    <dialog ref={registration} className="hex-dialog equipment-registration-modal" aria-labelledby={registrationTitle} onClose={() => setRegistering(false)}><HexModalFrame>
      <header className="pagehead"><h2 id={registrationTitle}>Register Equipment</h2><ModalClose type="button" className="secondary modal-close" onClick={closeRegistration} aria-label="Close dialog">×</ModalClose></header>
      {registering && allowed && <AssetForm categories={categories} expenses={expenses} expense={expense} back="" onSaved={() => {closeRegistration(); router.refresh();}}/>}
    </HexModalFrame></dialog>
    <dialog ref={detail} className="hex-dialog equipment-registration-modal" aria-labelledby={detailTitle} onClose={() => setSelected(null)}><HexModalFrame>
      <header className="pagehead"><h2 id={detailTitle}>{selected?.name ?? "Equipment details"}</h2><ModalClose type="button" className="secondary modal-close" onClick={closeDetail} aria-label="Close dialog">×</ModalClose></header>
      {selected && <dl className="equipment-detail-grid">
        <dt>Equipment ID</dt><dd>{selected.id}</dd>
        <dt>Category</dt><dd>{selected.category}</dd>
        <dt>Serial Number</dt><dd>{selected.serialNumber || "—"}</dd>
        <dt>Warranty Expiration</dt><dd>{selected.warrantyExpiration || "—"}</dd>
        <dt>Source</dt><dd>{selected.origin}</dd>
        <dt>Status</dt><dd>{selected.status}</dd>
        {selected.origin === "Purchased" ? <>
          <dt>Cost</dt><dd>{money(selected.purchaseCost ?? 0)}</dd>
          <dt>Purchase Date</dt><dd>{selected.purchaseDate || "—"}</dd>
          <dt>Vendor</dt><dd>{selected.vendor || "—"}</dd>
          <dt>Finance Transaction</dt><dd>{selected.expenseId ? <Link href={`/app/finance/transactions/${selected.expenseId}`}>{selected.expenseId}</Link> : "—"}</dd>
        </> : <>
          <dt>Estimated Value</dt><dd>{money(selected.estimatedValue ?? 0)}</dd>
          <dt>Donated By</dt><dd>{selected.donatedBy || "—"}</dd>
          <dt>Received Date</dt><dd>{selected.receivedDate || "—"}</dd>
        </>}
        <dt>Registered</dt><dd>{denverDateTime(selected.createdAt)}</dd>
        <dt>Notes</dt><dd className="equipment-notes">{selected.notes || "—"}</dd>
      </dl>}
    </HexModalFrame></dialog>
  </>;
}
