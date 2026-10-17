import type {ReactNode} from "react";

/** One sticky stack avoids fixed offsets when finance headers wrap on mobile. */
export function FinanceListFrame({header,controls,children}:{header?:ReactNode;controls?:ReactNode;children:ReactNode}) {
  return <section className="finance-list-workspace">
    <div className="finance-list-sticky">{header}{controls}</div>
    {children}
  </section>;
}
