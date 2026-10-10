"use client";
import {useActionState} from "react";
import {customerAction} from "@/app/actions";
import {money} from "@/lib/domain/money";
export function ReturnChoice({token,job,fee,chosen}:{token:string;job:string;fee:number;chosen:boolean}) {
 const [state,action,pending]=useActionState(customerAction.bind(null,"return-choice",token),{});
 return <section className="panel"><h2>Choose your next step</h2><p>Nothing was left at your door. Pick up at the shop for free, or choose a second delivery for {money(fee)}. The next available delivery route day is reserved provisionally. The trip is confirmed only after payment is verified. Unpaid reservations are released at the route cutoff or after 15 days; your items then stay at the shop for free pickup. If that attempt is missed, the fee is nonrefundable and shop pickup is required.</p><form action={action}><input type="hidden" name="job" value={job}/><button name="choice" value="shop" disabled={pending}>Free shop pickup · $0</button>{!chosen && <button name="choice" value="retry" disabled={pending}>Second delivery · {money(fee)}</button>}{chosen && <p>Second delivery selected. Complete payment below.</p>}{state.error && <p role="alert">{state.error}</p>}</form></section>;
}
