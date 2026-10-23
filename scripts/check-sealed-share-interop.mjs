// Encrypted share links across the two platforms: the app's own CloudShareSeal (CryptoKit)
// against the Worker's own src/lib/sealed-share.ts (WebCrypto, run in Node). No network.
// node scripts/check-sealed-share-interop.mjs <screendrop-worker checkout>
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const worker = process.argv[2];
assert.ok(worker, "usage: node scripts/check-sealed-share-interop.mjs <screendrop-worker checkout>");
const { keyFromFragment, openSealedFile, SealedShareError } = await import(pathToFileURL(resolve(worker, "src/lib/sealed-share.ts")));
const work = mkdtempSync(join(tmpdir(), "sealed-share-interop-"));
const cli = join(work, "sealed-share");
const built = spawnSync("swiftc", ["-O", "Screendrop/CloudShareSeal.swift", "scripts/sealed-share-cli.swift", "-o", cli], { encoding: "utf8" });
assert.equal(built.status, 0, built.stderr);
const run = (...args) => spawnSync(cli, args, { encoding: "utf8", maxBuffer: 64 << 20 });
let groups = 0;
const pass = (name) => console.log(`INTEROP PASS ${++groups}: ${name}`);
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const failure = async (promise) => {
  try { await promise; } catch (error) { return error instanceof SealedShareError ? error.reason : `other: ${error}`; }
  return "opened";
};

// The same bytes in both repos, and what the Swift code writes today.
const vectors = readFileSync("ScreendropTests/Fixtures/sealed-share-vectors.json", "utf8");
assert.equal(readFileSync(resolve(worker, "checks/fixtures/sealed-share-vectors.json"), "utf8"), vectors);
assert.equal(run("vectors").stdout, vectors);
pass("known-answer vectors match in both repos and the Swift output");

const MiB = 1024 * 1024;
const files = [
  ["empty.txt", "text/plain", Buffer.alloc(0)],
  ["one.bin", "application/octet-stream", Buffer.from([7])],
  ["Screenshot 2026-10-23 at 09.41.png", "image/png", randomBytes(300 * 1024)],
  ["Rechnung März – 日本.pdf", "application/pdf", randomBytes(5 * MiB + 3)],
  ["at-the-cap.zip", "application/zip", randomBytes(32 * MiB)],
];
for (const [name, type, bytes] of files) {
  const input = join(work, "input.bin");
  const sealedPath = join(work, "sealed.bin");
  writeFileSync(input, bytes);
  const sealed = run("seal", input, name, type, sealedPath);
  assert.equal(sealed.status, 0, sealed.stderr);
  const key = sealed.stdout.trim();
  assert.match(key, /^[A-Za-z0-9_-]{43}$/);
  const ciphertext = new Uint8Array(readFileSync(sealedPath));
  assert.equal(ciphertext.length, bytes.length + 4 + Buffer.byteLength(JSON.stringify({ contentType: type, filename: name })) + 28);
  const opened = await openSealedFile(ciphertext, keyFromFragment(`#${key}`));
  assert.deepEqual([opened.filename, opened.contentType, sha(opened.bytes)], [name, type, sha(bytes)]);
  // One flipped bit anywhere (nonce, body, tag) and a different key both fail as a wrong key.
  for (const index of [0, 12, ciphertext.length - 1]) {
    const tampered = ciphertext.slice();
    tampered[index] ^= 1;
    assert.equal(await failure(openSealedFile(tampered, keyFromFragment(`#${key}`))), "wrong-key", `${name} @${index}`);
  }
  assert.equal(await failure(openSealedFile(ciphertext, new Uint8Array(randomBytes(32)))), "wrong-key");
}
pass(`Swift seals, WebCrypto opens: ${files.length} files from 0 B to 32 MiB, real names and types, tampering and wrong keys fail`);

const over = join(work, "over.bin");
writeFileSync(over, randomBytes(32 * MiB + 1));
const refused = run("seal", over, "over.bin", "application/octet-stream", join(work, "over.sealed"));
assert.notEqual(refused.status, 0);
assert.match(refused.stderr, /tooLarge/);
pass("Swift refuses 32 MiB + 1 byte");

// The other way: WebCrypto seals with its own framing, the Swift code opens and unframes it.
async function webSeal(name, type, bytes, key) {
  const header = Buffer.from(JSON.stringify({ filename: name, contentType: type }));
  const plaintext = Buffer.concat([Buffer.from([0, 0, 0, 0]), header, bytes]);
  plaintext.writeUInt32BE(header.length, 0);
  const nonce = randomBytes(12);
  const cryptoKey = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  return Buffer.concat([nonce, Buffer.from(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, cryptoKey, plaintext))]);
}
for (const [name, type, bytes] of files.slice(0, 4)) {
  const key = randomBytes(32);
  const sealedPath = join(work, "web.sealed");
  const output = join(work, "web.out");
  writeFileSync(sealedPath, await webSeal(name, type, bytes, key));
  const keyText = key.toString("base64url");
  const opened = run("open", sealedPath, keyText, output);
  assert.equal(opened.status, 0, opened.stdout + opened.stderr);
  assert.deepEqual(JSON.parse(opened.stdout), { contentType: type, filename: name, size: bytes.length });
  assert.equal(sha(readFileSync(output)), sha(bytes));
  const wrong = run("open", sealedPath, randomBytes(32).toString("base64url"), output);
  assert.deepEqual([wrong.status, JSON.parse(wrong.stdout)], [2, { failure: "wrongKey" }]);
  const tampered = readFileSync(sealedPath);
  tampered[20] ^= 1;
  writeFileSync(sealedPath, tampered);
  assert.deepEqual(JSON.parse(run("open", sealedPath, keyText, output).stdout), { failure: "wrongKey" });
}
// A valid seal whose plaintext isn't the framing: Swift says unreadable, not a crash.
const key = randomBytes(32);
const sealedPath = join(work, "junk.sealed");
const nonce = randomBytes(12);
const cryptoKey = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
writeFileSync(sealedPath, Buffer.concat([nonce, Buffer.from(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, cryptoKey, Buffer.from([0xff, 0xff, 0xff, 0xff, 1, 2])))]));
assert.deepEqual(JSON.parse(run("open", sealedPath, key.toString("base64url"), join(work, "junk.out")).stdout), { failure: "unreadable" });
pass("WebCrypto seals, Swift opens and unframes; wrong keys, tampering and bad framing fail cleanly");
rmSync(work, { recursive: true });
console.log(`INTEROP ${groups}/4 passed`);
