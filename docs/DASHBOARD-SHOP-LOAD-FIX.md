# Dashboard and shop board load failures

## Diagnosis

Read-only production investigation on boft-core plus Vercel runtime logs confirmed:

- Dashboard `/app`: `Unable to load recent_activity: canceling statement due to statement timeout`. The grouped security-invoker view evaluates session/RBAC rules across thousands of audit fields before returning ten events. The same authenticated query reproduced a three-second statement timeout. The equivalent grouped read without per-field RLS evaluation completed in about 76 ms on the observed dataset.
- Shop `/app/pick-return`: `Could not load shop pick_return_orders`. The shared loader assumed every table had `id`. Production and the migrations show `pick_return_orders` is keyed by `job_id`, `quote_logistics` by `quote_id`, and failed-delivery verification by `stop_id`. The old query reproduced SQLSTATE 42703. Corrected reads returned existing records within the three-second limit. Queue/operator RPCs were present and readable.
- Support controls shared the generic wrapping actions styles. Dedicated horizontal control rows keep each section/status/origin group together, with local horizontal scrolling on narrow screens instead of vertical stacking.

## Implementation

`SHOP_BOARD_ORDER_KEYS` enumerates stable keys for every paged shop table. The shop loader uses that map, retains tenant filters, RLS and paging, and logs the database error message instead of hiding it behind a table-only error. Receiving cards use `job_id` as their React key. The initial leg also respects existing permissions: Return-only staff open Delivery, while Receiving-only staff cannot select an inaccessible Delivery leg. No additional permissions are granted.

The additive `20261016035358_dashboard_recent_activity_fast_path.sql` introduces a private guarded query and an unprivileged public RPC wrapper. The private helper checks an authenticated, active ToolTag Owner once, fixes the tenant and returns at most ten grouped summaries. It exposes no audit old/new payloads and changes no RLS policy or existing view. Non-Owners, expired sessions, anonymous callers and other business units cannot use it. Dashboard handles an unavailable activity panel with an explicit notice, preserving the rest of its data instead of fabricating an empty history or failing the whole page.

## Rollout

The migration is part of PR #14 and **has not been applied to production** by this task. Apply it only after review and authorization. Until it is applied, Dashboard shows the explicit activity-unavailable notice. No existing migration, baseline, Agreement, customer record, notification or production setting was changed during diagnosis.

Regression coverage binds every shop paging key to the actual isolated migrated schema and checks activity grouping, ten-event limit, tenant isolation, Owner-only access and expired sessions. Support rows are checked in an isolated browser at desktop/mobile widths.
