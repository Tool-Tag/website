"use client";
import {ModalClose} from "./modal-close";

import Link from "next/link";
import { useId, useRef, useState } from "react";

type AttentionItem = { path: string; kind: string };
const PAGE_SIZE = 10;

export function DashboardAttention({ items }: { items: AttentionItem[] }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const [page, setPage] = useState(0);
  const pages = Math.max(1, Math.ceil(items.length / PAGE_SIZE));
  const current = Math.min(page, pages - 1);

  function rows(list: AttentionItem[], inModal = false) {
    return <ul className="dashboard-attention-list">{list.map((item, index) => (
      <li key={`${item.path}-${item.kind}-${index}`}>
        <Link className="blue-electric menu-link-blue-electric dashboard-attention-link" href={item.path} onClick={inModal ? () => dialog.current?.close() : undefined}>↗ {item.kind}</Link>
      </li>
    ))}</ul>;
  }

  return <>
    {rows(items.slice(0, 5))}
    {items.length > 5 && <button type="button" className="secondary gold" aria-haspopup="dialog" onClick={() => { setPage(0); dialog.current?.showModal(); }}>View more</button>}
    <dialog ref={dialog} className="dashboard-attention-modal" aria-labelledby={titleId}>
      <header className="actions dashboard-attention-modal-header">
        <h2 id={titleId}>Needs Attention</h2>
        <ModalClose type="button" className="secondary modal-close" onClick={() => dialog.current?.close()} aria-label="Close dialog">×</ModalClose>
      </header>
      {rows(items.slice(current * PAGE_SIZE, (current + 1) * PAGE_SIZE), true)}
      <footer className="actions pagination dashboard-attention-pagination">
        <button type="button" className="secondary" disabled={current === 0} onClick={() => setPage(current - 1)}>Previous</button>
        <span role="status" aria-live="polite">Page {current + 1} of {pages}</span>
        <button type="button" className="secondary" disabled={current >= pages - 1} onClick={() => setPage(current + 1)}>Next</button>
      </footer>
    </dialog>
  </>;
}
