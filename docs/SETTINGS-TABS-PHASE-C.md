# Phase C — Owner settings tabs

Branch: `feature/roles-support-inbox`. Phase A and B approved for continuation per Martin. No push, PR, merge, deployment or production migration in this phase. Waiting for the next audit.

## Original page inventory

The previous single page included: AWS SNS SMS credentials/activation/test/log, automatic email mode/activation, Agreement versions and publishing approved text, rule summaries, timezone/BOFT URL/annual vehicle method/mileage rate, Zelle/Venmo identifiers, weekly route day selections/capacities, second delivery fee, categories/archive/create, notification history/individual retry, and the Phase A Users and roles tab.

## Final grouping

| Tab | Controls |
| --- | --- |
| General | New optional business display name/contact email/contact phone; existing timezone/BOFT URL/vehicle method/mileage rate; unchanged Agreement version view/publishing form; categories; existing rule summaries and future Drive note |
| Pick & Return | Existing Pickup/Return weekday selection and capacities; fixed 8 AM–12 PM / 2–6 PM Denver windows; optional shop departure reference address |
| Notifications | Existing SMS/AWS configuration and test/log; existing production email mode/activation/retry/log; link to Support/Hello inbox |
| Prices | Existing engraving rule display and logistics fees from LOGISTICS_OPTIONS; existing Zelle/Venmo identifiers and configurable second Return attempt fee; current Stripe configuration status |
| Users and roles | Existing Phase A owner administration, unchanged |

Owner access is enforced before rendering/loading any tab. Existing server/RLS guards remain. The optional profile RPC additionally requires current Owner authority; a custom role containing settings.manage cannot use it. No client role claim authorizes Settings. Unknown tab falls back to General; `/app/settings?tab=users` remains valid. Save destinations retain their current tab. Only the active tab loads its associated data/RPCs. Mobile tabs wrap into large touch targets.

## Additive migration (local, NOT applied)

`20261012074735_workspace_settings_profile.sql` adds four nullable columns to unit_settings:

- business_display_name (160 characters)
- business_contact_email (254 characters, validated email)
- business_contact_phone (40 characters)
- route_departure_address (1000 characters)

New public.save_workspace_profile(jsonb) patches only supplied profile fields, validates input, and scopes writes exclusively to ToolTag after private.require_owner. It cannot change BOFT records. Empty optional values clear to null. Audit records only field names, not contact/address values. All existing unit_settings RLS remains in place. No old migration/baseline was edited, no old save_settings RPC was replaced, and no profile data was seeded.

Apply only at authorized rollout, AFTER Phase A `20261012013207` and B `20261012044838`. This task did not apply any of them.

## Scope decisions for review

Route windows are shown read-only: the existing operational scheduling code uses fixed Pickup 08:00–12:00 and Return 14:00–18:00 America/Denver windows. This phase does not change window semantics, cutoffs, ETAs, bookings or the Agreement. Route days/capacities remain editable through the existing save_settings RPC.

Business profile fields describe the workspace only. They do not overwrite sender aliases, payment identifiers, customer records, receipts or immutable accepted document snapshots.

The departure address is an optional driver reference shown in both Pickup and Return route views. It does not become a geocoding origin; ETA remains based on the driver's live GPS. No replacement shop address was invented. When blank, the driver reference stays hidden.

Prices shows existing pricing rules; it does not introduce adjustable engraving rates, retroactive repricing or a second pricing engine. Existing second-attempt fee remains configurable. Zelle/Venmo values are loaded from stored settings, with no actual account or key hardcoded/seeded. Venmo is marked pending when unconfigured. Stripe keys and current test restrictions are unchanged.

The Agreement publishing form is preserved for Martin to use later; no Agreement text, version or acceptance was modified. Existing UI explanatory Spanish fragments on this Settings page were translated to English.

## Validation

Local typecheck/lint/tests/build results are recorded at phase completion. Meaningful new DB tests cover Owner-only and ToolTag-only writes, custom settings-block denial, anonymous execute denial, email/type/length validation, optional clearing, partial-update isolation between tabs, and unchanged policy text. No real notification/email/SMS was sent and no production/Auth data was changed.

CI stays configured for Node 22; local runtime is Node 24.11.1. Remote CI is pending publication. Phase C does not authorize deployment or production migration.

Completed local checks: typecheck, lint (no warnings), 125 automated tests (33 CJS + 92 TS), production build, and git diff whitespace check passed. No external email/SMS test was performed. Logs: /tmp/tooltag-settings-{typecheck,lint,tests,build}.log.
