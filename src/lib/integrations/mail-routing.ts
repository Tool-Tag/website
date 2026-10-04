type Env = Record<string, string | undefined>;

export function mailSender(event: string, env: Env = process.env) {
  const normalized = event.toUpperCase().replace(/[^A-Z0-9]+/g, "_");

  // Quote + Agreement messages stay on quotes@.
  // Everything after the initial acceptance flows through notifications@.
  const quotes = [
    "QUOTE_SENT",
    "QUOTE_EXPIRING",
    "QUOTE_EXPIRATION_REMINDER",
    "QUOTE_REVISION",
    "REVISION_REQUIRES_ACCEPTANCE",
    "AGREEMENT_ACCEPTED",
    "AGREEMENT_ACCEPTED_COPY",
  ];

  const department = quotes.includes(normalized)
    ? "QUOTES"
    : normalized === "GENERAL_CONTACT"
      ? "HELLO"
      : "NOTIFICATIONS";

  const address =
    env[`TOOLTAG_MAIL_${department}_FROM`] ||
    `${department.toLowerCase()}@tooltag.martinlab.studio`;

  const name =
    env[`TOOLTAG_MAIL_${department}_NAME`] ||
    (department === "HELLO"
      ? "ToolTag"
      : `ToolTag ${department[0]}${department.slice(1).toLowerCase()}`);

  return {
    from: `${name} <${address}>`,
    replyTo: env[`TOOLTAG_MAIL_${department}_REPLY_TO`] || address,
  };
}

// Reserved for a future vendor workflow; never selected by customer event routing.
export function vendorMailSender(env: Env = process.env) {
  const address =
    env.TOOLTAG_MAIL_PURCHASES_FROM || "purchases@tooltag.martinlab.studio";
  return {
    from: `${env.TOOLTAG_MAIL_PURCHASES_NAME || "ToolTag Purchases"} <${address}>`,
    replyTo: env.TOOLTAG_MAIL_PURCHASES_REPLY_TO || address,
  };
}
