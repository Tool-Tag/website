"use client";
import { useActionState } from "react";
import { mutate, type ActionState } from "@/app/actions";
export type Field = {
  name: string;
  label: string;
  type?: string;
  required?: boolean;
  value?: string;
  options?: { value: string; label: string }[];
  wide?: boolean;
  help?: string;
  suggestions?: string[];
};
export function Form({
  operation,
  fields,
  hidden = {},
  button = "Save",
  back = "/app",
  children,
}: {
  operation: string;
  fields: Field[];
  hidden?: Record<string, string>;
  button?: string;
  back?: string;
  children?: React.ReactNode;
}) {
  const [state, action, pending] = useActionState<ActionState, FormData>(
    mutate.bind(null, operation, back),
    {},
  );
  return (
    <form action={action} className="formgrid">
      {Object.entries(hidden).map(([k, v]) => (
        <input key={k} type="hidden" name={k} value={v} />
      ))}
      {fields.map((f) => (
        <label key={f.name} className={f.wide ? "wide" : ""}>
          {f.label}
          {f.type === "textarea" ? (
            <textarea
              name={f.name}
              required={f.required}
              defaultValue={f.value}
            />
          ) : f.options ? (
            <select
              name={f.name}
              required={f.required}
              defaultValue={f.value ?? ""}
            >
              <option value="">Select…</option>
              {f.options.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          ) : (
            <>
              <input
                list={f.suggestions ? `suggest-${f.name}` : undefined}
                name={f.name}
                type={f.type ?? "text"}
                required={f.required}
                defaultValue={f.value}
                step={f.type === "number" ? "0.01" : undefined}
              />
              {f.suggestions && (
                <datalist id={`suggest-${f.name}`}>
                  {f.suggestions.map((v) => (
                    <option key={v} value={v} />
                  ))}
                </datalist>
              )}
            </>
          )}
          {f.help && <small>{f.help}</small>}
        </label>
      ))}
      {children}
      {state.error && (
        <div role="alert" className="notice error wide">
          {state.error}
        </div>
      )}
      {state.link && (
        <div className="notice success wide">
          Link prepared. Check the notification log for the email delivery status.
          <br />
          <a href={state.link} target="_blank" rel="noreferrer">
            Open customer view ↗
          </a>
          <input
            aria-label="Customer link"
            readOnly
            value={
              typeof window !== "undefined"
                ? window.location.origin + state.link
                : state.link
            }
            onFocus={(e) => e.target.select()}
          />
        </div>
      )}
      {state.mailStatus && <p className="notice wide">{state.mailStatus}</p>}
      {state.ok && <div className="notice success wide">Saved.</div>}
      <button disabled={pending}>{pending ? "Saving…" : button}</button>
    </form>
  );
}
