import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, "..", "ps", "image_text.jsx"), "utf8");
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: "image_text.jsx" });

// vm 里创建的对象原型属于另一个 realm，先转成本 realm 的普通对象再比较。
const plain = (value) => JSON.parse(JSON.stringify(value));

test("moniMapBox maps normalized boxes into the target rect", () => {
  const mapped = plain(
    sandbox.moniMapBox(
      { x: 0.5, y: 0.5, w: 0.1, h: 0.1 },
      { x: 100, y: 50, w: 400, h: 200 }
    )
  );
  assert.deepEqual(mapped, { x: 300, y: 150, w: 40, h: 20 });
});

test("moniFontSizePt converts pixels to points using the document dpi", () => {
  assert.equal(sandbox.moniFontSizePt(0.1, 200, 72), 15.6);
  assert.equal(sandbox.moniFontSizePt(0.1, 200, 144), 7.8);
  assert.equal(sandbox.moniFontSizePt(0, 0, 0), 1);
});

test("moniLayerName collapses whitespace and truncates", () => {
  assert.equal(sandbox.moniLayerName("  hello \n  world  ", 40), "hello world");
  assert.equal(sandbox.moniLayerName("", 10), "Text");
  const truncated = sandbox.moniLayerName("abcdefghijklmnop", 8);
  assert.equal(truncated.length, 8);
  assert.ok(truncated.endsWith("\u2026"));
});

test("moniTextColor honours mode and falls back to black", () => {
  assert.deepEqual(plain(sandbox.moniTextColor("black", { r: 1, g: 2, b: 3 })), {
    r: 0,
    g: 0,
    b: 0,
  });
  assert.deepEqual(plain(sandbox.moniTextColor("white", null)), { r: 255, g: 255, b: 255 });
  assert.deepEqual(plain(sandbox.moniTextColor("sample", { r: 10, g: 20, b: 30 })), {
    r: 10,
    g: 20,
    b: 30,
  });
  assert.deepEqual(plain(sandbox.moniTextColor("sample", null)), { r: 0, g: 0, b: 0 });
});

test("moniClamp keeps values inside the range", () => {
  assert.equal(sandbox.moniClamp(-1, 0, 10), 0);
  assert.equal(sandbox.moniClamp(11, 0, 10), 10);
  assert.equal(sandbox.moniClamp(5, 0, 10), 5);
});
