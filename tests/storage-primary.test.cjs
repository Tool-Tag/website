const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

test("evidence and accepted PDFs write binaries to Supabase Storage", () => {
  const evidence = read("src/app/evidence-actions.ts");
  const accepted = read("src/lib/documents/accepted-delivery.ts");

  assert.match(evidence, /\.storage\s*\.from\(TOOLTAG_FILES_BUCKET\)\s*\.upload/);
  assert.match(evidence, /finish_document_storage/);
  assert.match(accepted, /\.storage\s*\.from\(TOOLTAG_FILES_BUCKET\)\s*\.upload/);
  assert.match(accepted, /finish_accepted_pdf_storage/);
  assert.doesNotMatch(evidence, /metadata-only phase|Google Drive is connected/);
});

test("active Drive integration stub and new Drive-link input are retired", () => {
  const contracts = read("src/lib/integrations/contracts.ts");
  const finance = read("src/features/finance.tsx");
  const settings = read("src/features/settings.tsx");
  const actions = read("src/app/actions.ts");

  assert.doesNotMatch(contracts, /DocumentStore|export const drive|Google Drive/);
  assert.doesNotMatch(finance, /Existing Drive File ID|button="Link Receipt"/);
  assert.match(finance, /<EvidenceUpload/);
  assert.doesNotMatch(settings, /title="Google Drive"|drive_root_id|Documents \/ Drive/);
  assert.doesNotMatch(actions, /case "document"/);
});

test("Storage migration creates private buckets, RLS and stored/failed lifecycle", () => {
  const sql = read(
    "supabase/migrations/20261010005200_supabase_storage_primary.sql",
  );

  assert.match(sql, /'tooltag-files','tooltag-files',false/);
  assert.match(sql, /'quote-images','quote-images',false/);
  assert.match(sql, /create policy tooltag_files_admin_insert/);
  assert.match(sql, /storage_provider='supabase_storage'/);
  assert.match(sql, /storage_status='stored'/);
  assert.match(sql, /storage_status='failed'/);
  assert.match(sql, /Legacy Drive references are read-only/);
  assert.doesNotMatch(sql, /set default 'pending_drive'/);
});

test("stored files have authenticated and customer-token download routes", () => {
  const internal = read("src/app/app/documents/[id]/download/route.ts");
  const customer = read(
    "src/app/status/[token]/documents/[id]/download/route.ts",
  );
  const customerPage = read(
    "src/app/status/[token]/documents/[id]/page.tsx",
  );

  assert.match(internal, /\.storage\s*\.from\(document\.storage_bucket\)\s*\.download/);
  assert.match(customer, /public_job_document/);
  assert.match(customer, /storageAdmin/);
  assert.match(customerPage, /View \/ download document/);
});

test("historical Drive references remain explicitly read-only", () => {
  const finance = read("src/features/finance.tsx");
  const customers = read("src/features/customers.tsx");
  const storage = read("docs/STORAGE.md");

  assert.match(finance, /Legacy Drive reference/);
  assert.match(customers, /legacy Drive reference/);
  assert.match(storage, /preserved read-only|preserved read-only/i);
  assert.match(storage, /Every ID currently resolves to a \*\*folder\*\*/);
});
