const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const React = require('react');
const {renderToStaticMarkup} = require('react-dom/server');

// Render the actual composer without Next routing or any Gmail/database calls.
const file = path.resolve(__dirname, '../src/components/support-conversation.tsx');
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
 compilerOptions: {module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2022},
}).outputText;
const exportsObject = {};
vm.runInNewContext(compiled, {
 exports: exportsObject,
 require(name) {
  if (name === 'next/navigation') return {useRouter: () => ({refresh() {}})};
  if (name === '@/app/support-actions') return {
   markSupportRead: async () => ({ok: true}),
   replySupport: async () => {throw new Error('Rendering must not send email');},
   closeSupportCase: async () => {throw new Error('Rendering must not resolve cases');},
  };
  return require(name);
 },
});
const render = sendEnabled => renderToStaticMarkup(React.createElement(exportsObject.SupportConversation, {
 id:'00000000-0000-4000-8000-000000000001', through:'2026-10-17T12:00:00Z', closed:false, canClose:false, sendEnabled,
}));

test('staff can compose a Support reply when Gmail delivery is disabled, without enabling sending', () => {
 const html = render(false);
 const textarea = html.match(/<textarea\b[^>]*>/)?.[0];
 assert.ok(textarea, 'reply textarea is rendered');
 assert.doesNotMatch(textarea, /\bdisabled(?:=|\s|>)/);
 assert.match(html, /You can write a reply/);
 assert.match(html, /<button[^>]*disabled[^>]*>Send reply<\/button>/);
});

test('a configured Support composer remains editable and cannot submit an empty reply', () => {
 const html = render(true);
 assert.doesNotMatch(html.match(/<textarea\b[^>]*>/)?.[0] || '', /\bdisabled(?:=|\s|>)/);
 assert.doesNotMatch(html, /You can write a reply/);
 assert.match(html, /<button[^>]*disabled[^>]*>Send reply<\/button>/);
});
