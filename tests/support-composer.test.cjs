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
const closureContext = React.createContext(null);
const hexExports={};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.resolve(__dirname,'../src/components/hex-modal-frame.tsx'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX,target:ts.ScriptTarget.ES2022}}).outputText,{exports:hexExports,require});
const exportsObject = {};
vm.runInNewContext(compiled, {
 exports: exportsObject,
 require(name) {
  if (name === './hex-modal-frame') return hexExports;
  if (name === './support-case-modal') return {SupportClosureContext: closureContext};
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

for (const label of ['End Inquiry', 'Close case']) {
 test(`${label} uses the danger action beside Send reply without submitting the reply form`, () => {
  const html = renderToStaticMarkup(React.createElement(closureContext.Provider, {
   value:{open(){throw new Error('Rendering must not run closure');},pending:false,closed:false,label},
  }, React.createElement(exportsObject.SupportConversation, {
   id:'00000000-0000-4000-8000-000000000001',through:'2026-10-17T12:00:00Z',closed:false,canClose:false,sendEnabled:true,
  })));
  assert.match(html, new RegExp(`<button type="button" class="danger support-end-inquiry">${label}</button>`));
  assert.ok(html.indexOf('Send reply') < html.indexOf(label));
 });
}
test('resolved conversations do not expose a protocol close action', () => {
 const html = renderToStaticMarkup(React.createElement(closureContext.Provider, {
  value:{open(){},pending:false,closed:true,label:'End Inquiry'},
 }, React.createElement(exportsObject.SupportConversation, {
  id:'00000000-0000-4000-8000-000000000001',through:'2026-10-17T12:00:00Z',closed:true,canClose:false,sendEnabled:true,
 })));
 assert.doesNotMatch(html, /support-end-inquiry/);
});
