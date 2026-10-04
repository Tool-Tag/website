type Env = Record<string, string | undefined>;
export function mailSender(event: string, env: Env = process.env) {
  const normalized = event.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
  const quotes = ["QUOTE_SENT", "QUOTE_EXPIRING", "QUOTE_EXPIRATION_REMINDER", "QUOTE_REVISION", "REVISION_REQUIRES_ACCEPTANCE", "AGREEMENT_ACCEPTED", "AGREEMENT_ACCEPTED_COPY", "JOB_CONFIRMED"];
  const billing = ["PAYMENT_RECEIPT", "FINAL_PAID_RECEIPT", "PAYMENT_DUE", "PAYMENT_SUBMITTED", "REFUND_UPDATE"];
  const support = ["ISSUE_OPENED", "ISSUE_UPDATE", "CUSTOMER_CLAIM", "CUSTOMER_REPORTED_ISSUE"];
  const department = quotes.includes(normalized) ? "QUOTES" : billing.includes(normalized) ? "BILLING" : support.includes(normalized) ? "SUPPORT" : normalized === "GENERAL_CONTACT" ? "HELLO" : "NOTIFICATIONS";
  const address = env[`TOOLTAG_MAIL_${department}_FROM`] || `${department.toLowerCase()}@tooltag.martinlab.studio`;
  const name = env[`TOOLTAG_MAIL_${department}_NAME`] || (department === "HELLO" ? "ToolTag" : `ToolTag ${department[0]}${department.slice(1).toLowerCase()}`);
  return { from: `${name} <${address}>`, replyTo: env[`TOOLTAG_MAIL_${department}_REPLY_TO`] || address };
}

// Reserved for a future vendor workflow; never selected by customer event routing.
export function vendorMailSender(env: Env = process.env) {
  const address = env.TOOLTAG_MAIL_PURCHASES_FROM || "purchases@tooltag.martinlab.studio";
  return {from: `${env.TOOLTAG_MAIL_PURCHASES_NAME || "ToolTag Purchases"} <${address}>`, replyTo: env.TOOLTAG_MAIL_PURCHASES_REPLY_TO || address};
}
