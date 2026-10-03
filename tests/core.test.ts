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
