import { test } from "node:test";
import assert from "node:assert/strict";
import { needsSecondFactor, fieldFor, secondFactorBody, ticketIsGone } from "../modules/login.js";
import { twoFactorText, recoveryText, cleanCode } from "../modules/account.js";

test("the second step is needed only when the panel says so and gives a ticket", () => {
  assert.equal(needsSecondFactor({ ok: false, totp_required: true, ticket: "t1" }), true);
  assert.equal(needsSecondFactor({ ok: true }), false);
  assert.equal(needsSecondFactor({ totp_required: true }), false, "no ticket, nothing to send back");
  assert.equal(needsSecondFactor(undefined), false);
  assert.equal(needsSecondFactor(null), false);
});

test("the code field is six digits for the app and ten characters for a recovery code", () => {
  const app = fieldFor(false);
  assert.equal(app.inputMode, "numeric");
  assert.ok(new RegExp("^" + app.pattern + "$").test("123456"));
  assert.ok(new RegExp("^" + app.pattern + "$").test("123 456"));
  assert.ok(!new RegExp("^" + app.pattern + "$").test("12345"));
  const rec = fieldFor(true);
  assert.equal(rec.inputMode, "text");
  assert.ok(new RegExp("^" + rec.pattern + "$").test("abcde-fghjk"));
  assert.ok(!new RegExp("^" + rec.pattern + "$").test("short"));
  assert.notEqual(app.label, rec.label);
  assert.notEqual(app.switchText, rec.switchText);
});

test("the second request carries the ticket and one kind of code, without spaces", () => {
  assert.deepEqual(secondFactorBody("T", false, " 123 456 "), { ticket: "T", code: "123456" });
  assert.deepEqual(secondFactorBody("T", true, "abcde fghjk"), { ticket: "T", recovery: "abcdefghjk" });
  assert.deepEqual(secondFactorBody("T", false, undefined), { ticket: "T", code: "" });
});

test("a wrong code keeps the ticket, an ended ticket or a block sends the person back", () => {
  assert.equal(ticketIsGone({ status: 401, message: "wrong code" }), false);
  assert.equal(ticketIsGone({ status: 401, message: "the sign-in took too long or did not start here: enter the password again" }), true);
  assert.equal(ticketIsGone({ status: 429, message: "too many sign-in attempts, try again later" }), true);
  assert.equal(ticketIsGone({ status: 500, message: "boom" }), false);
  assert.equal(ticketIsGone(undefined), false);
});

test("the account section says what is on, shows codes one per line and cleans typed codes", () => {
  assert.match(twoFactorText(true), /is on/);
  assert.match(twoFactorText(false), /is off/);
  assert.equal(recoveryText(["aaaaa-bbbbb", "ccccc-ddddd"]), "aaaaa-bbbbb\nccccc-ddddd");
  assert.equal(recoveryText(undefined), "");
  assert.equal(cleanCode(" 123 456\n"), "123456");
  assert.equal(cleanCode(null), "");
});
