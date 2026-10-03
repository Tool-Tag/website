"use client";
import { useActionState, useState } from "react";
import { mutate } from "@/app/actions";
export function SendQuote({ id }: { id: string }) {
  const [state, action, pending] = useActionState(
    mutate.bind(null, "send-quote", `/app/quotes/${id}`),
    {},
  );
  const [copied, setCopied] = useState(false);
  return (
    <>
      <form action={action}>
        <input type="hidden" name="id" value={id} />
        <button disabled={pending}>
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
              Cotización lista. Correo pendiente: Google Workspace aún no está
              conectado. Copia el enlace para compartirlo.
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
