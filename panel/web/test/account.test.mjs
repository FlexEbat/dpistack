import { test } from "node:test";
import assert from "node:assert/strict";
import { visibleViews, refusal, VIEW_PERM } from "../modules/account.js";

const views = ["overview", "configs", "rules", "account"];

test("a viewer does not see Configs, an account with the permission does", () => {
  assert.deepEqual(visibleViews(views, ["view"]), ["overview", "rules", "account"]);
  assert.deepEqual(visibleViews(views, ["view", "configs.edit"]), views);
});

test("only Configs hides a menu entry: every other screen is readable with view", () => {
  assert.deepEqual(Object.keys(VIEW_PERM), ["configs"]);
});

test("a refusal names the missing permission and nothing else is rewritten", () => {
  assert.match(refusal({ error: "forbidden", permission: "rules.edit" }), /rules\.edit/);
  assert.equal(refusal({ error: "wrong CSRF token" }), "");
  assert.equal(refusal(undefined), "");
});
