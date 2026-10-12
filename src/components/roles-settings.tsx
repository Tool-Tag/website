"use client";
import { useActionState, useState } from "react";
import { saveRole, saveStaffUser, inviteStaffUser, resetStaffCredentials, type RbacResult } from "@/app/rbac-actions";
type Block = {key:string; description:string; area:string};
type Role = {id:string; name:string; system_key:string|null; blocks:string[]};
type Staff = {id:string; email:string; name:string; active:boolean; roles:string[]};
export type RoleDirectory = {blocks:Block[]; roles:Role[]; users:Staff[]};
function Result({state}: {state:RbacResult}) {return state.error ? <p role="alert" className="notice error">{state.error}</p> : state.ok ? <p role="status" className="notice success">Saved / request submitted.</p> : null;}
function RoleEditor({role,blocks}: {role?:Role; blocks:Block[]}) {
  const [selected,setSelected]=useState(role?.blocks??[]);
  const [state,action,pending]=useActionState(saveRole,{});
  const owner=role?.system_key==="Owner";
  return <form action={action} className="stack"><input type="hidden" name="id" value={role?.id??""}/><label>Role name<input name="name" defaultValue={role?.name??""} required maxLength={80} disabled={owner}/></label>
    {owner?<p className="notice">Owner includes every current and future permission automatically. This system role cannot be edited.</p>:<>{[...new Set(blocks.map(b=>b.area))].map(area=><fieldset key={area}><legend>{area}</legend>{blocks.filter(b=>b.area===area).map(b=><label className="checkbox" key={b.key}><input type="checkbox" name="blocks" value={b.key} checked={selected.includes(b.key)} onChange={e=>setSelected(current=>e.target.checked?[...current,b.key]:current.filter(k=>k!==b.key))}/>{b.description}<small> · {b.key}</small></label>)}</fieldset>)}<section className="notice"><strong>What this role can do</strong>{selected.length?<ul>{blocks.filter(b=>selected.includes(b.key)).map(b=><li key={b.key}>{b.description}</li>)}</ul>:<p>No permissions selected.</p>}<p>Settings and user/role administration remain Owner-only. Driver permissions only apply to assigned routes.</p></section><button disabled={pending}>Save role</button></>}
    <Result state={state}/>
  </form>;
}
function RoleChoices({roles,selected=[]}: {roles:Role[];selected?:string[]}) {return <fieldset><legend>Roles · select all that apply</legend>{roles.map(role=><label className="checkbox" key={role.id}><input type="checkbox" name="roles" value={role.id} defaultChecked={selected.includes(role.id)}/>{role.name}</label>)}</fieldset>;}
function StaffEditor({user,roles}: {user:Staff;roles:Role[]}) {
  const [state,action,pending]=useActionState(saveStaffUser,{});
  const [reset,resetAction,resetPending]=useActionState(resetStaffCredentials,{});
  return <article className="panel"><h3>{user.name||user.email}</h3><p>{user.email} · {user.active?"Active":"Disabled"}</p><form action={action} className="stack"><input type="hidden" name="id" value={user.id}/><label>Display name<input name="name" defaultValue={user.name} maxLength={100}/></label><label className="checkbox"><input type="checkbox" name="active" defaultChecked={user.active}/>Active ToolTag access</label><RoleChoices roles={roles} selected={user.roles}/><button disabled={pending}>Save user access</button><Result state={state}/></form><form action={resetAction}><input type="hidden" name="id" value={user.id}/><button className="secondary" disabled={resetPending}>Send credential reset email</button><Result state={reset}/></form><p className="muted">Disabling ToolTag access takes effect on the next request. It does not disable this person&apos;s other business accounts.</p></article>;
}
function AddStaff({roles}: {roles:Role[]}) {
  const [invite,inviteAction,inviting]=useActionState(inviteStaffUser,{});
  const [existing,existingAction,saving]=useActionState(saveStaffUser,{});
  return <><details className="panel"><summary>Invite a new user</summary><form action={inviteAction} className="stack"><label>Email<input name="email" type="email" required/></label><label>Display name<input name="name" maxLength={100}/></label><RoleChoices roles={roles}/><button disabled={inviting}>Send invitation</button><Result state={invite}/></form></details><details className="panel"><summary>Add an existing Auth user</summary><form action={existingAction} className="stack"><label>User ID<input name="id" required/></label><label>Display name<input name="name" maxLength={100}/></label><input type="hidden" name="active" value="on"/><RoleChoices roles={roles}/><button disabled={saving}>Add ToolTag access</button><Result state={existing}/></form></details></>;
}
export function RolesSettings({directory}: {directory:RoleDirectory}) {
 return <section><h2>Users and roles</h2><p>Permissions from multiple roles are combined. Access is checked by the server and database, not only hidden in the menu.</p><details className="panel"><summary>Permission blocks</summary>{directory.blocks.map(b=><p key={b.key}><code>{b.key}</code> · {b.description} · {b.area}</p>)}</details><h3>Roles</h3>{directory.roles.map(role=><details className="panel" key={role.id}><summary>{role.name}</summary><RoleEditor key={JSON.stringify(role)} role={role} blocks={directory.blocks}/></details>)}<details className="panel"><summary>Create role</summary><RoleEditor blocks={directory.blocks}/></details><h3>Users</h3>{directory.users.map(user=><StaffEditor key={JSON.stringify(user)} user={user} roles={directory.roles}/>)}<AddStaff roles={directory.roles}/></section>;
}
