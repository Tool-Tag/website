"use client";

import { Fragment, useActionState, useEffect, useRef, useState, type ReactNode } from "react";
import { saveRole, saveStaffUser, inviteStaffUser, resetStaffCredentials, type RbacResult } from "@/app/rbac-actions";
import { HexModalFrame, ModalActions } from "./hex-modal-frame";
import { ModalClose } from "./modal-close";

type Block = { key: string; description: string; area: string };
type Role = { id: string; name: string; system_key: string | null; blocks: string[] };
type Staff = { id: string; email: string; name: string; active: boolean; roles: string[] };
export type RoleDirectory = { blocks: Block[]; roles: Role[]; users: Staff[] };
type RoleDraft = { name: string; blocks: string[] };

function Result({ state, success = "Saved." }: { state: RbacResult; success?: string }) {
  return state.error ? <p role="alert" className="notice error">{state.error}</p>
    : state.ok ? <p role="status" className="notice success">{success}</p> : null;
}

function SettingsDialog({ title, children, close }: { title: string; children: ReactNode; close: () => void }) {
  return <HexModalFrame><h2>{title}</h2><ModalClose onClick={close} />{children}</HexModalFrame>;
}

function RoleChoices({ roles, selected = [] }: { roles: Role[]; selected?: string[] }) {
  return <fieldset className="role-chips"><legend>Roles · select all that apply</legend>
    {roles.map(role => <label key={role.id}>
      <input type="checkbox" name="roles" value={role.id} defaultChecked={selected.includes(role.id)} />
      <span>{role.name}</span>
    </label>)}
  </fieldset>;
}

function CreateRole({ roles, blocks }: { roles: Role[]; blocks: Block[] }) {
  const [selected, setSelected] = useState<string[]>([]);
  const [state, action, pending] = useActionState(saveRole, {});
  return <form action={action} className="stack">
    <label>Role name<input name="name" required maxLength={80} /></label>
    <label>Copy permissions from<select defaultValue="" onChange={event => {
      const role = roles.find(role => role.id === event.target.value);
      setSelected(role?.system_key === "Owner" ? blocks.map(block => block.key) : role?.blocks ?? []);
    }}><option value="">Start with no permissions</option>
      {roles.map(role => <option key={role.id} value={role.id}>{role.name}</option>)}
    </select></label>
    <fieldset><legend>Permissions</legend>
      {blocks.map(block => <label className="checkbox" key={block.key}>
        <input type="checkbox" name="blocks" value={block.key} checked={selected.includes(block.key)}
          onChange={event => setSelected(event.target.checked ? [...selected, block.key] : selected.filter(key => key !== block.key))} />
        {block.description}
      </label>)}
    </fieldset>
    <Result state={state} success="Role created." />
    {!state.ok && <ModalActions><button className="gold" disabled={pending}>Create role</button></ModalActions>}
  </form>;
}

function AddStaff({ roles }: { roles: Role[] }) {
  const [invite, inviteAction, inviting] = useActionState(inviteStaffUser, {});
  const [existing, existingAction, saving] = useActionState(saveStaffUser, {});
  const [mode, setMode] = useState("invite");
  const isInvite = mode === "invite";
  const state = isInvite ? invite : existing;
  return <>
    <label>How should this user join?<select value={mode} onChange={event => setMode(event.target.value)}>
      <option value="invite">Send email invitation</option><option value="existing">Link existing account</option>
    </select></label>
    <form key={mode} action={isInvite ? inviteAction : existingAction} className="stack">
      {isInvite ? <label>Email<input name="email" type="email" required /></label>
        : <><label>Existing account reference<input name="id" type="password" autoComplete="off" required /></label>
          <input type="hidden" name="active" value="on" /></>}
      <label>Display name<input name="name" maxLength={100} /></label>
      <RoleChoices roles={roles.filter(role => role.system_key !== "Owner")} />
      <Result state={state} success={isInvite ? "Invitation sent." : "ToolTag access added."} />
      {!state.ok && <ModalActions><button className="gold" disabled={inviting || saving}>
        {isInvite ? "Send invitation" : "Add ToolTag access"}
      </button></ModalActions>}
    </form>
  </>;
}

function StaffRow({ user, roles }: { user: Staff; roles: Role[] }) {
  const [state, action, pending] = useActionState(saveStaffUser, {});
  const [reset, resetAction, resetPending] = useActionState(resetStaffCredentials, {});
  const formId = `staff-access-${user.id}`;
  return <tr>
    <td data-label="User"><form id={formId} action={action}>
      <input type="hidden" name="id" value={user.id} />
      <input name="name" aria-label={`Display name for ${user.email}`} defaultValue={user.name} maxLength={100} />
    </form></td>
    <td data-label="Email">{user.email}</td>
    <td data-label="Roles"><div className="role-chips" role="group" aria-label={`Roles for ${user.email}`}>
      {roles.map(role => <label key={role.id}>
        <input form={formId} type="checkbox" name="roles" value={role.id} defaultChecked={user.roles.includes(role.id)} />
        <span>{role.name}</span>
      </label>)}
    </div></td>
    <td data-label="Active"><label className="role-switch">
      <input form={formId} type="checkbox" name="active" aria-label={`Active access for ${user.email}`} defaultChecked={user.active} />
      <span aria-hidden="true" />
    </label></td>
    <td data-label="Actions"><div className="role-user-actions">
      <button type="submit" form={formId} className="secondary" disabled={pending}>Save access</button>
      <form action={resetAction}>
        <input type="hidden" name="id" value={user.id} />
        <button className="secondary" disabled={resetPending}>Send credential reset</button>
      </form>
      <Result state={state} /><Result state={reset} success="Credential reset requested." />
    </div></td>
  </tr>;
}

export function RolesSettings({ directory }: { directory: RoleDirectory }) {
  const { blocks, roles, users } = directory;
  const areas = [...new Set(blocks.map(block => block.area))];
  const [view, setView] = useState<"matrix" | "role" | null>(null);
  const [activeId, setActiveId] = useState(roles.find(role => role.system_key !== "Owner")?.id);
  const [drafts, setDrafts] = useState<Record<string, RoleDraft>>({});
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<RbacResult>({});
  const [dialog, setDialog] = useState<"role" | "user" | null>(null);
  const modal = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = modal.current;
    if (dialog && element && !element.open) element.showModal();
  }, [dialog]);
  const active = roles.find(role => role.id === activeId) ?? roles[0];
  const owner = (role: Role) => role.system_key === "Owner";
  const value = (role: Role) => drafts[role.id] ?? role;
  const checked = (role: Role, block: Block) => owner(role) || value(role).blocks.includes(block.key);
  const count = (role: Role) => blocks.filter(block => checked(role, block)).length;
  const changed = roles.filter(role => !owner(role) && drafts[role.id]);
  const changeCount = changed.reduce((total, role) => total + Number(value(role).name !== role.name)
    + blocks.filter(block => checked(role, block) !== role.blocks.includes(block.key)).length, 0);

  function update(role: Role, next: RoleDraft) {
    if (owner(role)) return;
    setResult({});
    setDrafts(current => {
      const updated = { ...current, [role.id]: next };
      if (next.name === role.name && next.blocks.length === role.blocks.length &&
        next.blocks.every(block => role.blocks.includes(block))) delete updated[role.id];
      return updated;
    });
  }

  function toggle(role: Role, block: Block) {
    const draft = value(role);
    update(role, { name: draft.name, blocks: checked(role, block)
      ? draft.blocks.filter(key => key !== block.key) : [...draft.blocks, block.key] });
  }

  async function saveChanges() {
    setSaving(true);
    setResult({});
    const saved: string[] = [];
    let failure = "";
    try {
      for (const role of changed) {
        const draft = value(role);
        const form = new FormData();
        form.set("id", role.id);
        form.set("name", draft.name);
        for (const block of draft.blocks) form.append("blocks", block);
        const response = await saveRole({}, form);
        if (!response.ok) {
          failure = `${role.name}: ${response.error ?? "Could not save role."}`;
          break;
        }
        saved.push(role.id);
      }
    } catch {
      failure = "Could not finish saving roles. Check the connection and try again.";
    } finally {
      setDrafts(current => Object.fromEntries(Object.entries(current).filter(([id]) => !saved.includes(id))));
      setResult(failure ? { error: `${saved.length ? `${saved.length} role(s) saved. ` : ""}${failure}` } : { ok: true });
      setSaving(false);
    }
  }

  function openModal(kind: "role" | "user") {
    setDialog(kind);
  }

  return <section className="roles-settings roles-workspace">
    <h2>Users &amp; Roles</h2>
    <p className="muted">Permissions from multiple roles are combined.</p>
    <div className="roles-toolbar">
      <h3>Roles</h3>
      <div className="roles-view-choice" data-view={view ?? "auto"} role="group" aria-label="Role view">
        <button type="button" className="secondary roles-matrix-choice" aria-pressed={view === "matrix" ? true : view === "role" ? false : undefined} onClick={() => setView("matrix")}>Matrix</button>
        <button type="button" className="secondary roles-role-choice" aria-pressed={view === "role" ? true : view === "matrix" ? false : undefined} onClick={() => setView("role")}>By role</button>
      </div>
      <button type="button" className="secondary" onClick={() => openModal("role")}>+ Create role</button>
    </div>

    <div className="roles-views" data-view={view ?? "auto"}>
      <section className="panel roles-matrix">
        <div className="roles-matrix-scroll">
          <table aria-label="Permissions by role">
            <thead><tr><th scope="col">Permission</th>{roles.map(role => <th scope="col" key={role.id}>
              {role.name} <span className="badge">{count(role)} / {blocks.length}</span>
            </th>)}</tr></thead>
            {areas.map(area => <tbody key={area}>
              <tr className="roles-area-row"><th scope="rowgroup" colSpan={roles.length + 1}>{area}</th></tr>
              {blocks.filter(block => block.area === area).map(block => <tr key={block.key}>
                <th scope="row">{block.description}</th>
                {roles.map(role => <td key={role.id} data-label={role.name}>
                  <input type="checkbox" aria-label={`${role.name}: ${block.description}`} checked={checked(role, block)}
                    disabled={owner(role) || saving} onChange={() => toggle(role, block)} />
                </td>)}
              </tr>)}
            </tbody>)}
          </table>
        </div>
        <p className="roles-owner-note">Owner automatically includes every current and future permission.</p>
      </section>

      <section className="panel roles-by-role">
        <nav className="main-tab-list" aria-label="Choose a role">
          {roles.map(role => <button type="button" key={role.id} className="main-tab" aria-current={active?.id === role.id ? "page" : undefined}
            onClick={() => setActiveId(role.id)}>{role.name} · {count(role)} / {blocks.length}</button>)}
        </nav>
        {active && (owner(active) ? <p className="notice">Owner automatically includes every current and future permission.</p> : <>
          <label>Role name<input value={value(active).name} maxLength={80} disabled={saving}
            onChange={event => update(active, { name: event.target.value, blocks: value(active).blocks })} /></label>
          {areas.map(area => <fieldset className="roles-group" key={area}><legend>{area}</legend>
            {blocks.filter(block => block.area === area).map(block => <label key={block.key}>
              <span className="role-switch"><input type="checkbox" checked={checked(active, block)} disabled={saving}
                onChange={() => toggle(active, block)} /><span aria-hidden="true" /></span>
              {block.description}
            </label>)}
          </fieldset>)}
        </>)}
      </section>
    </div>

    <div className="roles-savebar">
      <span role="status">{changeCount ? `${changeCount} unsaved ${changeCount === 1 ? "change" : "changes"}` : "No unsaved changes"}</span>
      <div className="actions">
        <button type="button" className="secondary" disabled={!changeCount || saving} onClick={() => { setDrafts({}); setResult({}); }}>Discard</button>
        <button type="button" className="gold" disabled={!changeCount || saving || changed.some(role => !value(role).name.trim())}
          onClick={() => void saveChanges()}>{saving ? "Saving…" : "Save roles"}</button>
      </div>
    </div>
    <Result state={result} success="Roles saved." />

    <div className="roles-toolbar">
      <h3>Users</h3><span className="badge">{users.filter(user => user.active).length} active</span>
      <button type="button" className="gold" onClick={() => openModal("user")}>+ Add user</button>
    </div>
    <div className="tablewrap roles-users">
      <table aria-label="Users">
        <thead><tr>{["User", "Email", "Roles", "Active", "Actions"].map(label => <th key={label} scope="col">{label}</th>)}</tr></thead>
        <tbody>{users.map(user => <StaffRow key={JSON.stringify(user)} user={user} roles={roles} />)}</tbody>
      </table>
    </div>
    <p className="muted">Active means ToolTag access is enabled. Invited users still need to accept their invitation and choose a password. If the link expired or was already used, send a credential reset email.</p>

    <dialog ref={modal} className="action-modal roles-settings-modal" aria-label={dialog === "role" ? "Create role" : "Add user"} onClose={() => setDialog(null)}>
      {dialog && <SettingsDialog title={dialog === "role" ? "Create role" : "Add user"} close={() => modal.current?.close()}>
        <Fragment key={dialog}>{dialog === "role" ? <CreateRole roles={roles} blocks={blocks} /> : <AddStaff roles={roles} />}</Fragment>
      </SettingsDialog>}
    </dialog>
  </section>;
}
