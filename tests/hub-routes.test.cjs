const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../dist');

for (const route of ['/hub', '/hub/', '/hub/falcon', '/hub/falcon/']) {
  test(`links and assets resolve correctly from ${route}`, () => {
    const html = fs.readFileSync(path.join(root, route, 'index.html'), 'utf8');
    for (const [, value] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
      assert.ok(value.startsWith('/'), `Must be root-relative: ${value}`);
      const url = new URL(value, `https://tooltag.martinlab.studio${route}`);
      assert.ok(fs.existsSync(path.join(root, url.pathname)), `Missing: ${url.pathname}`);
    }
    assert.ok(html.includes('href="/hub/hub.css"'));
    assert.ok(html.includes('ToolTag is a registered DBA of Bandits of the Framing LLC.'));
    if (!route.includes('falcon')) assert.ok(html.includes('href="/hub/falcon/"'));
    else for (const file of ['falcon.js','falcon-data.js','falcon-presets.js'])
      assert.ok(html.includes(`src="/hub/falcon/${file}"`));
  });
}

test('Hub logo asset exists and styles match ToolTag colors', () => {
  const css = fs.readFileSync(path.join(root, 'hub/hub.css'), 'utf8');
  for (const [, value] of css.matchAll(/url\(['"]?([^)'"\s]+)['"]?\)/g))
    assert.ok(fs.existsSync(path.join(root, value)));
  const homeCSS = fs.readFileSync(path.join(root, 'styles.css'), 'utf8');
  for (const name of ['bg','panel','text','muted','blue','gold','line']) {
    const pattern = new RegExp(`--${name}:([^;}]+)`);
    assert.equal(css.match(pattern)[1],homeCSS.match(pattern)[1]);
  }
});
