"use client";
import { useActionState, useState } from "react";
import { mutate } from "@/app/actions";
export function SendQuote({ id, email, companyEmail }: { id: string; email?: string; companyEmail?: string }) {
  const recipients = [
    { label: "Correo personal", email: email?.trim() || "" },
    { label: "Correo de compañía", email: companyEmail?.trim() || "" },
  ].filter((entry, index, all) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(entry.email) && all.findIndex((other) => other.email.toLowerCase() === entry.email.toLowerCase()) === index);
  const [state, action, pending] = useActionState(
    mutate.bind(null, "send-quote", `/app/quotes/${id}`),
    {},
  );
  const [copied, setCopied] = useState(false);
  return (
    <>
      <form action={action}>
        <input type="hidden" name="id" value={id} />
        {recipients.length > 1 ? (
          <label>
            ¿A cuál correo quieres enviar la cotización?
            <select name="recipient" required defaultValue="" disabled={pending}>
              <option value="" disabled>Selecciona un correo…</option>
              {recipients.map((entry) => <option key={entry.email} value={entry.email}>{entry.label}: {entry.email}</option>)}
            </select>
          </label>
        ) : (
          <>
            <input type="hidden" name="recipient" value={recipients[0]?.email || ""} />
            <p>{recipients.length ? `Enviar a: ${recipients[0].email}` : "Agrega un correo al cliente antes de enviar."}</p>
          </>
        )}
        <button disabled={pending || !recipients.length}>
          {pending ? "Preparando…" : "Enviar cotización"}
        </button>
        <label className="checkbox">
          <input type="checkbox" name="regenerate" />
          Regenerar enlace e invalidar el anterior
        </label>
        {state.error && (
          <p role="alert" className="notice error">
            {state.error}
          </p>
        )}
        {state.link && (
          <div className="notice">
            <p>
              {state.mailStatus || "Cotización lista. Puedes copiar el enlace para compartirlo."}
            </p>
            <input
              aria-label="Enlace privado"
              readOnly
              value={window.location.origin + state.link}
            />
            <div className="actions">
              <button
                type="button"
                className="secondary"
                onClick={async () => {
                  setCopied(false);
                  try {
                    await navigator.clipboard.writeText(
                      window.location.origin + state.link!,
                    );
                    setCopied(true);
                  } catch {
                    /* The selectable field remains available. */
                  }
                }}
              >
                {copied ? "Copiado" : "Copiar enlace"}
              </button>
              <a href={state.link} target="_blank" rel="noreferrer">
                Ver página del cliente
              </a>
            </div>
          </div>
        )}
      </form>
      <p>
        <a href={`/app/quotes/${id}/email`}>Vista previa del correo</a>
      </p>
    </>
  );
}
