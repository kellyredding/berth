#!/usr/bin/env node
// validate-js.mjs — syntax-check the JavaScript embedded in BerthApp's Swift
// source before xcodebuild runs. Galaxy's gate, adapted.
//
// xcodebuild treats JavaScript inside a Swift `"""` literal as opaque string
// data, so a syntax error there compiles clean and fails only at runtime in
// the web view. A literal opts in with a marker on the line just above its
// declaration:
//
//     // js-validate
//     static let source = """
//     ... javascript ...
//     """
//
// Each literal is unescaped as Swift would materialize it, then parsed with
// `new vm.Script`, which never runs it. Syntax only: references and logic are
// out of scope.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const MARKER = "// js-validate";
const APP_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC_DIR = join(APP_ROOT, "BerthApp");

// A marked literal that moves out of this tree is not reported missing; it
// just stops being found and everything left passes. Lower this only in the
// change that moves a literal, once its new home validates it.
const EXPECTED_MIN_LITERALS = 4;

// Swift's `"""` unescaping. Load-bearing: the source `/\n/g` is a valid regex
// to node, but Swift turns its `\n` into a real newline, which is not.
// `\(…)` interpolations become `0` so the surrounding JavaScript still parses.
function unescapeSwiftMultiline(src) {
  let out = "";
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (ch !== "\\") {
      out += ch;
      continue;
    }
    const next = src[i + 1];
    switch (next) {
      case "n": out += "\n"; i++; break;
      case "t": out += "\t"; i++; break;
      case "r": out += "\r"; i++; break;
      case "0": out += "\0"; i++; break;
      case "\\": out += "\\"; i++; break;
      case '"': out += '"'; i++; break;
      case "'": out += "'"; i++; break;
      case "\n": i++; break;
      case "u": {
        const m = /^\\u\{([0-9A-Fa-f]+)\}/.exec(src.slice(i));
        if (m) {
          out += String.fromCodePoint(parseInt(m[1], 16));
          i += m[0].length - 1;
        } else {
          out += ch;
        }
        break;
      }
      case "(": {
        let depth = 0;
        let j = i + 1;
        for (; j < src.length; j++) {
          if (src[j] === "(") depth++;
          else if (src[j] === ")") {
            depth--;
            if (depth === 0) break;
          }
        }
        out += "0";
        i = j;
        break;
      }
      default:
        out += ch;
    }
  }
  return out;
}

function extractMarkedLiterals(text) {
  const lines = text.split("\n");
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() !== MARKER) continue;
    let openIdx = -1;
    for (let j = i + 1; j < Math.min(i + 4, lines.length); j++) {
      if (/"""\s*$/.test(lines[j])) {
        openIdx = j;
        break;
      }
    }
    if (openIdx === -1) {
      found.push({ name: "(unknown)", line: i + 1, error: `${MARKER} marker not followed by a """ literal within 3 lines` });
      continue;
    }
    const name = /(?:let|var)\s+(\w+)/.exec(lines[openIdx])?.[1] ?? "(anonymous)";
    const body = [];
    let closeIdx = -1;
    for (let j = openIdx + 1; j < lines.length; j++) {
      if (lines[j].trim() === '"""') {
        closeIdx = j;
        break;
      }
      body.push(lines[j]);
    }
    if (closeIdx === -1) {
      found.push({ name, line: openIdx + 1, error: 'unterminated """ literal' });
      continue;
    }
    found.push({ name, line: openIdx + 1, js: unescapeSwiftMultiline(body.join("\n")) });
  }
  return found;
}

function* swiftFiles(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      yield* swiftFiles(full);
    } else if (entry.endsWith(".swift")) {
      yield full;
    }
  }
}

const failures = [];
let checked = 0;
for (const file of swiftFiles(SRC_DIR)) {
  const rel = relative(APP_ROOT, file);
  for (const found of extractMarkedLiterals(readFileSync(file, "utf8"))) {
    if (found.error) {
      failures.push({ file: rel, literal: found.name, line: found.line, err: new Error(found.error) });
      continue;
    }
    checked++;
    try {
      new vm.Script(found.js, { filename: `${rel}:${found.name}` });
    } catch (err) {
      failures.push({ file: rel, literal: found.name, line: found.line, err });
    }
  }
}

if (failures.length === 0 && checked >= EXPECTED_MIN_LITERALS) {
  console.log(`✓ JS validation passed — ${checked} embedded literal(s)`);
  process.exit(0);
}
if (checked < EXPECTED_MIN_LITERALS) {
  console.error(
    `\n✗ JS validation coverage dropped — found ${checked} embedded literal(s), expected at least ` +
      `${EXPECTED_MIN_LITERALS}. A literal that left this tree is not reported missing; if the move ` +
      `was intended, lower the floor in this file in the same change.\n`,
  );
}
if (failures.length > 0) {
  console.error(`\n✗ JS validation failed — ${failures.length} error(s)\n`);
  for (const f of failures) {
    console.error(`  ${f.file} → ${f.literal} (declared at line ${f.line})`);
    console.error(`    ${f.err.message.split("\n")[0]}`);
    const frame = (f.err.stack ?? "").split("\n").slice(0, 4).filter((l) => l.trim().length).slice(0, 3);
    for (const line of frame) console.error(`    ${line}`);
    console.error("");
  }
}
process.exit(1);
