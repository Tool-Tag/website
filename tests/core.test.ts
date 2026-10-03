import { test } from "node:test";
import assert from "node:assert/strict";
import { cents, decimal, quoteTotal } from "../src/lib/domain/money";
import { drive, email, evidenceName } from "../src/lib/integrations/contracts";
test("Money calculations use integer cents, including fractional unit prices", () => {
  assert.equal(
    quoteTotal([
      { quantity: 3, unit_price: "0.10" },
      { quantity: 1, unit_price: "0.20" },
    ]),
    "0.50",
  );
  assert.equal(decimal(cents("999999999999.99")), "999999999999.99");
  for (const invalid of ["1.001", "-1", "NaN", "1e2", ""])
    assert.throws(() => cents(invalid));
});
test("Adapters never pretend an upload or message succeeded", async () => {
  await assert.rejects(
    () => drive.upload("root", "receipt", new Uint8Array(), "image/jpeg"),
    /not connected/,
  );
  await assert.rejects(
    () =>
      email.send({
        recipient: "test@example.test",
        subject: "Test",
        body: "Test",
        idempotencyKey: "test",
      }),
    /not connected/,
  );
  assert.equal(
    evidenceName("TT-J-2026-00124", "Receiving", 2),
    "TT-J-2026-00124-Receiving-02.jpg",
  );
});

import { loginFailure } from "../src/lib/domain/auth-errors";
test("Login errors distinguish configuration from credentials without leaking raw messages", () => {
  assert.equal(
    loginFailure({ message: "Invalid API key" }).reference,
    "AUTH_CONFIG",
  );
  assert.equal(
    loginFailure({ code: "invalid_credentials", status: 400 }).reference,
    "invalid_credentials",
  );
  assert.equal(
    loginFailure({ code: "email_not_confirmed" }).reference,
    "email_not_confirmed",
  );
  assert.equal(loginFailure({ status: 429 }).reference, "AUTH_RATE_LIMIT");
  const unknown = loginFailure({
    message: "private token and internal details",
  });
  assert.equal(unknown.reference, "AUTH_UNAVAILABLE");
  assert.ok(!unknown.message.includes("private token"));
});

import { blankItem, withAdaptation } from "../src/lib/domain/quote-items";
test("Logo adaptation charges once per distinct link, across quantities and articles", () => {
  const a = {
    ...blankItem(),
    quantity: 10,
    unit_price: "2.00",
    marks: [
      {
        type: "Image / Logo" as const,
        text: "",
        url: "https://example.com/a.png",
      },
    ],
  };
  const b = { ...a, quantity: 2 };
  assert.equal(quoteTotal(withAdaptation([a, b])), "27.00");
  const c = {
    ...a,
    quantity: 1,
    marks: [
      ...a.marks,
      {
        type: "Image / Logo" as const,
        text: "",
        url: "https://example.com/b.png",
      },
    ],
  };
  assert.equal(quoteTotal(withAdaptation([a, b, c])), "32.00");
  assert.equal(
    quoteTotal(withAdaptation([{ ...blankItem(), unit_price: "2.00" }])),
    "2.00",
  );
});
