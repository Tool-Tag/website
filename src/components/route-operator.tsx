"use client";
import { useActionState } from "react";
import { assignRouteOperator } from "@/app/rbac-actions";
export function RouteOperator({route,current,operators}: {route:string;current?:string|null;operators:{id:string;name:string}[]}) {
 const [state,action,pending]=useActionState(assignRouteOperator,{});
 return <form action={action} className="formgrid"><input name="route" value={route} type="hidden"/><label>Route operator<select name="operator" defaultValue={current??""}><option value="">Unassigned · hidden from drivers</option>{operators.map(operator=><option key={operator.id} value={operator.id}>{operator.name}</option>)}</select></label><button disabled={pending}>Assign operator</button>{state.error&&<p role="alert">{state.error}</p>}{state.ok&&<p role="status">Operator assigned.</p>}</form>;
}
