#!/usr/bin/env node
// Converts a Playwright JUnit report into the framework's results CSV:
//   id,type,role,route,expected,actual,verdict,ms
//
// Standard library only (node:fs, node:path) — no xml2js, no fast-xml-parser.
// The JUnit shape here is narrow and well known (Playwright's own writer), so
// a small regex walk is more honest than pulling in a parser for it.
//
// Usage: node junit-to-csv.mjs tests/results/junit.xml tests/results/run-<ts>.csv
import { readFileSync, writeFileSync } from 'node:fs';

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) {
  console.error('usage: junit-to-csv.mjs <junit.xml> <out.csv>');
  process.exit(1);
}

const xml = readFileSync(inFile, 'utf8');

// The case id is the leading token of the test name/title, e.g.
// "INV-014 create an invoice" -> "INV-014". This is the js.md convention:
// hyphenated ids survive as-is inside a JS string, so no re-encoding is
// needed the way Python/Java/.NET identifiers require.
// Multi-segment prefixes are real: `tf.sh rbac` emits RBAC-USER-002.
const ID_RE = /([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*-\d+)/;

function attr(tag, name) {
  const m = tag.match(new RegExp(name + '="([^"]*)"'));
  return m ? m[1] : '';
}

function csvField(v) {
  const s = String(v ?? '');
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

const rows = ['id,type,role,route,expected,actual,verdict,ms'];

// Each <testcase ...> is either self-closing (pass) or wraps a <failure>/
// <error>/<skipped> child. Walk them as whole elements, not line by line —
// a JUnit file is not guaranteed to be one testcase per line.
// The quantifier MUST be lazy. Greedy `[^>]*` consumes the `/` of a
// self-closing tag, so the `\/>` branch can no longer match and the pattern
// falls through to `>...</testcase>` -- swallowing the NEXT case and pairing
// this case with that one's failure.
const caseRe = /<testcase\b[^>]*?(?:\/>|>[\s\S]*?<\/testcase>)/g;
for (const tag of xml.match(caseRe) ?? []) {
  const name = attr(tag, 'name');
  const idMatch = name.match(ID_RE);
  if (!idMatch) continue; // not one of ours (e.g. a beforeAll hook)
  const id = idMatch[1];

  const ms = Math.round(parseFloat(attr(tag, 'time') || '0') * 1000);
  let verdict = 'PASS';
  if (/<error\b/.test(tag)) verdict = 'ERROR';
  else if (/<failure\b/.test(tag)) verdict = 'FAIL';
  else if (/<skipped\b/.test(tag)) verdict = 'SKIP';

  const msgMatch = tag.match(/<(?:failure|error)\b[^>]*message="([^"]*)"/);
  const actual = msgMatch ? msgMatch[1] : (verdict === 'PASS' ? 'ok' : '');

  // type/role/route are not in JUnit output at all — the spec-writer agent
  // stamped only the id into the test name. Leave them for the caller to
  // fold back in from testcases.csv by id if it needs them; this adapter's
  // job is verdict + timing, which is all `tf.sh setmany` consumes.
  rows.push([id, 'ui', '', '', '', csvField(actual), verdict, ms].join(','));
}

writeFileSync(outFile, rows.join('\n') + '\n');
console.error(`junit-to-csv: wrote ${rows.length - 1} rows to ${outFile}`);
