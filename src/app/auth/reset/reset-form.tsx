"use client";
import {useActionState} from "react";
import {updatePassword} from "./reset-action";
export function CredentialReset(){const[state,action,pending]=useActionState(updatePassword,{});return <form className="stack" action={action}><label>New password<input type="password" name="password" autoComplete="new-password" minLength={12} required/></label><label>Confirm password<input type="password" name="confirm" autoComplete="new-password" minLength={12} required/></label><button disabled={pending}>Save password</button>{state.error&&<p role="alert">{state.error}</p>}</form>;}
