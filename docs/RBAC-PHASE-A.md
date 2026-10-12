# Phase A — roles, permission blocks and route operators

## Review status

Implementation is local on `feature/roles-support-inbox`, based on main `edd50dc1eeb1456030c4051985ca9985d6b27e20`.
**Do not publish or apply the migration before Muse approves.** No PR, merge, push or production migration was performed. Phase B (Support Inbox) and Phase C (full Settings tabs) remain deferred.

## Authorization model

- `permission_blocks`: the 18 requested keys, descriptions and areas.
- `roles`, `role_blocks`, `user_roles`: unit-scoped roles; each user may have multiple roles. Their permissions are combined.
- `staff_access`: ToolTag activation and display name. Disabling access takes effect on the next server/DB request, without banning the global Auth account or changing BOFT memberships.
- Owner includes every current and future block; its system role cannot be edited. Existing ToolTag legacy admins are bootstrapped into Owner. Legacy viewers are not promoted and require an explicit role assignment.
- Employee has exactly the requested 12 blocks; Driver has `driver.routes` only.
- Custom roles should combine view and manage blocks for the modules they need. Necessary record lookups for operations are permitted by database policies, while navigation and actions use their explicit blocks. Settings and user/role administration are Owner-only, even if a custom role selects their system blocks.
- Unknown mutation operations remain Owner-only. New tables require explicit permission policies; they do not inherit a broad staff grant.

Authority comes from current database rows, never `user_metadata` or a role cached in a JWT. `context.role = admin` remains an Owner-only compatibility label for the existing Settings renderer; legacy membership `role` does not confer ToolTag authority.

## Enforcement

1. Permission-filtered navigation, mutation forms, quote editors, evidence uploads and driver controls.
2. Fresh authenticated server context and per-action checks, including dedicated route/shop/SMS actions and quote-image upload.
3. RLS restrictions on existing tenant records, protected RBAC tables, metadata-bound Storage policies, and permission checks inside existing definer RPCs.

The new migration mechanically replaces guard calls in current function definitions. It preserves existing RPC names/arguments and operation bodies. Unlisted privileged operations stay Owner-only. BOFT retains its legacy membership authorization; tests verify that ToolTag roles do not grant BOFT access and BOFT reads remain available to its existing admin.

Financial records and receipt files require money permissions. A job-view grant does not grant receipts or financial audit records. Drivers get a scoped balance RPC for their route rather than general ledger access. Shared physical bank visibility retains the original cross-unit protection.

## Driver scope

The original schema had no `operator_id`. Martin explicitly approved adding it to each route, referencing the authenticated user.

- Driver-only users land at `/pick-return`; ordinary staff land in `/app`.
- Drivers see/execute only their assigned routes, stops and related records. Unassigned routes are hidden.
- Owner/route planners assign an active operator in the shop route view. Active routes can be reassigned for replacements; closed routes cannot. Assignment is audited and immediately changes driver scope.
- Cash confirmation is limited to the driver's Arrived Return stop and its Cash/Final Balance request. Receipt generation uses the same scope; arbitrary electronic payment confirmation is denied.
- Receiving/Delivery photos must belong to the assigned stop and job. Financial or mismatched customer/quote associations are rejected.
- Storage insert/upsert is limited to the uploader's metadata-bound document path. Finalization requires a stored object at that path; other people's evidence cannot be finalized by a driver.
- Shop Returned-item verification requires `pr.returns`; Driver cannot substitute for shop verification.
- Route responses do not return customer completion capabilities to non-Owners. The legacy acknowledgment-link RPC remains Owner-only.
- Session refresh also covers `/pick-return`.

## Users and roles UI

Settings adds a **Users and roles** tab; the existing Settings content is retained for Phase C inventory/reorganization.

The Owner can inspect blocks, create/edit roles with a permission preview, assign multiple roles, activate/deactivate ToolTag access, invite a new Auth user, add an existing Auth user by ID, and request a recovery email. The last active Owner cannot be removed. Credentials are never displayed or logged.

Invitations use the existing server-only Supabase admin credential; recovery emails use Supabase Auth. The recipient sets their own password through `/auth/reset`. The callback only accepts the fixed reset destination or `/app`, not arbitrary redirects.

## Manual Auth configuration after approval

No new secret environment variables are introduced. Invitations reuse the existing `SUPABASE_SECRET_KEY` or `SUPABASE_SERVICE_ROLE_KEY`; neither is exposed to the client.

Supabase Auth must have an email provider capable of invitations/recovery and allow this redirect:

`https://tooltag.martinlab.studio/auth/callback?next=/auth/reset`

Add the equivalent localhost URL only for an explicitly chosen development server. Existing customer Gmail notification/template logic is unchanged. No real invitation/recovery email was sent during implementation/tests.

## Migration / rollout gate

New, unapplied migration:

`20261012013207_roles_permissions_driver_scope.sql`

It creates the RBAC tables, adds route operator assignment, seeds the approved presets, adds policies and guard helpers, and upgrades authorization without changing Agreement content or immutable accepted snapshots. No applied migration or baseline was edited.

After approval, apply/verify the database migration before deploying code that requires `staff_permissions`. Before that, the branch intentionally fails closed against an unupgraded database; do not add a legacy-admin fallback. Verify PostgREST sees the new RPCs and the existing Owner can log in before inviting other users. Production application remains a separate approval step.

## Local verification

- `npm run typecheck`: pass.
- `npm run lint`: pass, no warnings.
- `npm test`: 116 pass (33 CJS + 83 TypeScript).
- `npm run build`: pass.
- DB tests run all six canonical baselines plus additive migrations in isolated PGlite; no production test customers, jobs, users, notifications or files are created.
- Checks cover presets/unions, future Owner permissions, last-Owner protection, no anonymous execute/direct RBAC writes, new Owner with legacy viewer membership, disabled sessions, assigned/foreign routes and incidents, route balance privacy, cash idempotence, actual metadata/Storage insert+upsert+finalization, forged-file rejection, customer capability suppression, Employee payment recording and BOFT isolation.

CI has not run for this branch because publication is prohibited pending Muse's review. Local verification does not claim a new CI or Vercel result.
