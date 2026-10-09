const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

test("desktop Get Tagged CTAs open a modal while links remain valid fallbacks", () => {
  const html = read("public/index.html");
  const js = read("public/app.js");
  const css = read("public/styles.css");

  assert.equal((html.match(/href="\/get-tagged"/g) || []).length, 3);
  assert.match(html, /id="get-tagged-dialog"/);
  assert.match(html, /data-src="\/get-tagged\/modal"/);
  assert.match(js, /matchMedia\('\(min-width: 1024px\)'\)/);
  assert.match(js, /if \(!desktopGetTagged\.matches/);
  assert.match(js, /event\.target === getTaggedDialog/);
  assert.match(js, /tooltag:get-tagged-close/);
  assert.match(css, /\.get-tagged-dialog\{/);
  assert.match(css, /@media\(max-width:1023px\)/);
});

test("modal route reuses GetTaggedForm and keeps success inside the modal", () => {
  const form = read("src/components/get-tagged-form.tsx");
  const modal = read("src/components/get-tagged-modal-content.tsx");
  const page = read("src/app/get-tagged/modal/page.tsx");
  const css = read("src/app/globals.css");

  assert.match(modal, /<GetTaggedForm modal onSuccess=\{setReference\}/);
  assert.match(modal, /REQUEST RECEIVED/);
  assert.match(modal, />Close<\/button>/);
  assert.match(modal, /event\.key === "Escape"/);
  assert.match(form, /intake-submit-sticky/);
  assert.match(form, /if \(onSuccess\)/);
  assert.match(page, /GetTaggedModalContent/);
  assert.match(css, /\.intake-submit-sticky/);
  assert.match(css, /position: sticky/);
});
