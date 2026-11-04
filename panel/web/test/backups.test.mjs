import { test } from "node:test";
import assert from "node:assert/strict";
import { humanSize, madeAt, requestUrl, restoreBody, nothingToChange } from "../modules/backups.js";

test("sizes are shown in the unit that fits", () => {
  assert.equal(humanSize(0), "0 B");
  assert.equal(humanSize(1023), "1023 B");
  assert.equal(humanSize(2048), "2.0 KiB");
  assert.equal(humanSize(5 * 1024 * 1024), "5.0 MiB");
  assert.equal(humanSize(undefined), "");
  assert.equal(humanSize(-1), "");
});

test("the time of the manifest reads like the other screens", () => {
  assert.equal(madeAt("2026-11-04T10:00:00Z"), "2026-11-04 10:00:00");
  assert.equal(madeAt(undefined), "");
});

test("the name of an archive cannot add a path or a parameter", () => {
  assert.equal(requestUrl("dpistack-backup-1.tar.gz", "verify"), "/api/backups/dpistack-backup-1.tar.gz/verify");
  assert.equal(requestUrl("a/../b?x=1.tar.gz"), "/api/backups/a%2F..%2Fb%3Fx%3D1.tar.gz");
});

test("a restore request says whether it is the preview or the confirmed one", () => {
  assert.deepEqual(JSON.parse(restoreBody(true)), { dry_run: true });
  assert.deepEqual(JSON.parse(restoreBody(false)), { acknowledged: true });
});

test("a preview where every file is the same has nothing to restore", () => {
  assert.equal(nothingToChange("same:    dpistack.conf\nsame:    suricata.yaml\ndry run: nothing was changed"), true);
  assert.equal(nothingToChange("same:    dpistack.conf\nchanged: suricata.yaml\n-a\n+b"), false);
  assert.equal(nothingToChange("new:     disable.conf"), false);
  assert.equal(nothingToChange(""), false);
});
