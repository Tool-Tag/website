"use client";
import { useActionState } from "react";
import { login } from "@/app/actions";
export function LoginForm() {
  const [state, action, pending] = useActionState(login, {});
  return (
    <form action={action} className="stack">
      <label>
        Email
        <input name="email" type="email" autoComplete="username" required />
      </label>
      <label>
        Contraseña
        <input
          name="password"
          type="password"
          autoComplete="current-password"
          required
        />
      </label>
      {state.error && (
        <p role="alert" className="notice error">
          {state.error}
        </p>
      )}
      <button disabled={pending}>{pending ? "Entrando…" : "Entrar"}</button>
    </form>
  );
}
