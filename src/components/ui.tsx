import {displayLabel} from "@/lib/domain/ui-labels";
import { money } from "@/lib/domain/money";
export function Heading({
  title,
  subtitle,
  children,
}: {
  title: React.ReactNode;
  subtitle?: string;
  children?: React.ReactNode;
}) {
  return (
    <header className="pagehead">
      <div>
        <p className="eyebrow">ToolTag / Workspace</p>
        <h1>{title}</h1>
        {subtitle && <p className="muted">{subtitle}</p>}
      </div>
      <div className="actions">{children}</div>
    </header>
  );
}
export function Panel({
  title,
  children,
}: {
  title?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="panel">
      {title && <h2>{title}</h2>}
      {children}
    </section>
  );
}
export function Metric({
  label,
  value,
  help,
  currency = true,
  tone,
}: {
  label: string;
  value: unknown;
  help?: string;
  currency?: boolean;
  tone?: "positive" | "negative";
}) {
  return (
    <div className={`metric${tone ? ` metric-${tone}` : ""}`}>
      <span className="muted">{label}</span>
      <strong>{currency ? money(value) : String(value ?? 0)}</strong>
      {help && <small>{help}</small>}
    </div>
  );
}
export function Empty({
  children = "No records yet.",
}: {
  children?: React.ReactNode;
}) {
  return <p className="empty">{children}</p>;
}
export function Badge({ children }: { children: React.ReactNode }) {
  return <span className="badge">{typeof children==="string"?displayLabel(children):children}</span>;
}
export function Table({
  headers,
  children,
}: {
  headers: string[];
  children: React.ReactNode;
}) {
  return (
    <div className="tablewrap">
      <table>
        <thead>
          <tr>
            {headers.map((h) => (
              <th key={h}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}
export {FinanceTabs} from "./finance-tabs";
