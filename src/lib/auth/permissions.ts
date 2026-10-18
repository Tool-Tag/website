/** Authorization keys are shared by navigation and server actions; SQL is authoritative. */
export const PERMISSION_BLOCKS = [
  ["jobs.view", "View jobs", "Operations"],
  ["jobs.manage", "Manage jobs and extensions", "Operations"],
  ["production.work", "Work on production items", "Operations"],
  ["quotes.view", "View quotes and requests", "Operations"],
  ["quotes.manage", "Create, review and send quotes", "Operations"],
  ["customers.view", "View customers", "Operations"],
  ["pr.routes.plan", "Plan and assign routes", "Pick & Return"],
  ["pr.routes.live", "Operate live routes", "Pick & Return"],
  ["pr.receiving", "Verify received pieces at the shop", "Pick & Return"],
  ["pr.returns", "Verify returned pieces and close returns", "Pick & Return"],
  ["pr.reschedule", "Reschedule stops", "Pick & Return"],
  ["payments.record", "Record and verify payments", "Money"],
  ["payments.view", "View financial records", "Money"],
  ["payments.refund", "Issue and confirm refunds", "Money"],
  ["settings.manage", "Manage workspace settings", "System"],
  ["users.manage", "Manage users and roles", "System"],
  ["driver.routes", "Operate assigned routes, collect route cash and upload evidence", "Driver"],
  ["support.inbox", "Read and reply to the support inbox", "Support"],
] as const;
export type Permission = (typeof PERMISSION_BLOCKS)[number][0];
export type Access = { owner: boolean; blocks: readonly string[] };
export const EMPLOYEE_BLOCKS: Permission[] = ["jobs.view", "jobs.manage", "production.work", "quotes.view", "customers.view", "pr.routes.plan", "pr.routes.live", "pr.receiving", "pr.returns", "pr.reschedule", "payments.record", "support.inbox"];
export function can(access: Access, permission: string) {
  return access.owner || access.blocks.includes(permission);
}
export function canAny(access: Access, permissions: readonly string[]) {
  return access.owner || permissions.some(permission => can(access, permission));
}
export function driverOnly(access: Access) {
  return !access.owner && can(access, "driver.routes") && !access.blocks.some(block => block !== "driver.routes");
}
export const ACTION_PERMISSIONS: Record<string, readonly Permission[]> = {
  "accepted-document": ["quotes.manage"], "prepare-accepted-document": ["quotes.manage"],
  "activate-live-mail": ["settings.manage"], "retry-notification": ["settings.manage"],
  "request-extension": ["jobs.manage"], "extension-send": ["quotes.manage"], "extension-cancel": ["jobs.manage"],
  "generate-receipt": ["payments.record"], "confirm-payment": ["payments.record"],
  "customer-stage": ["jobs.manage"], "get-tagged-review": ["quotes.manage"], "extension-scope": ["quotes.manage"],
  quote: ["quotes.manage"], "resend-quote": ["quotes.manage"], "send-quote": ["quotes.manage"],
  "get-tagged-approve": ["quotes.manage"], "get-tagged-reject": ["quotes.manage"],
  job: ["jobs.manage"], "job-item": ["production.work"], "complete-production": ["production.work"], "complete-job-work": ["production.work"],
  "pick-return-schedule": ["pr.reschedule"], "route-cash": ["payments.record", "driver.routes"],
  "shop-handover": ["pr.returns"], "route-confirm": ["pr.receiving", "pr.returns", "pr.routes.live", "driver.routes"],
  "pick-return-stop": ["pr.routes.live", "driver.routes"], "cancellation-refund": ["payments.refund"],
  settings: ["settings.manage"], "publish-policy": ["settings.manage"],
};
/** Unknown operations remain Owner-only; the fallback never grants a new capability. */
export function canMutate(access: Access, operation: string) {
  if (access.owner) return true;
  if (["settings","sms-cost-settings","publish-policy","activate-live-mail","retry-notification"].includes(operation)) return false;
  return canAny(access, ACTION_PERMISSIONS[operation] ?? []);
}
export function sectionPermissions(section: string): readonly Permission[] {
  switch (section) {
    case "lost": return ["jobs.view","pr.returns"];
    case "jobs": case "job-extensions": return ["jobs.view"];
    case "quotes": case "get-tagged": case "accepted-documents": return ["quotes.view"];
    case "support": case "notifications": return ["support.inbox"];
    case "customers": return ["customers.view"];
    case "pick-return": return ["pr.routes.plan", "pr.routes.live", "pr.receiving", "pr.returns", "pr.reschedule"];
    case "finance": case "finance-hub": case "job-receipts": case "proofpayment": return ["payments.view"];
    case "refunds": return ["payments.refund","payments.view"];
    case "equipment": return ["settings.manage"];
    case "settings": return []; // Owner-only even when a custom role includes settings.manage.
    default: return ["jobs.view", "quotes.view", "customers.view"];
  }
}
export function evidencePermissions(type: string, routeStop = false): readonly string[] {
  if (type === "Receiving Evidence") return ["pr.receiving", ...(routeStop ? ["driver.routes","pr.routes.live"] : [])];
  if (type === "Delivery Evidence") return ["pr.returns", ...(routeStop ? ["driver.routes","pr.routes.live"] : [])];
  if (type === "Refund Review Evidence") return ["jobs.manage","payments.refund"];
  if (["Issue / Review Evidence","Cancellation Evidence"].includes(type)) return ["jobs.manage"];
  if (["Preparation Evidence","Production Evidence","Completed Evidence","Finished Evidence"].includes(type)) return ["production.work"];
  if (type === "Payment screenshot") return ["payments.record"];
  return []; // Unclassified file types require Owner.
}
