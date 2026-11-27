// The second step of a sign-in (two factor): what the panel answers after the
// password, and what the second form sends. Pure, so a test can run it.

// True when the password was right and a code is still needed.
export function needsSecondFactor(res) {
  return Boolean(res && res.totp_required && res.ticket);
}

// The code field in each mode: the 6 digits of the app, or a recovery code
// (xxxxx-xxxxx).
export function fieldFor(recovery) {
  return recovery
    ? {
        label: "Recovery code",
        pattern: "[A-Za-z0-9 \\-]{10,12}",
        maxLength: 12,
        inputMode: "text",
        switchText: "Use the code of the app instead",
      }
    : {
        label: "Code from your authenticator app",
        pattern: "[0-9 ]{6,7}",
        maxLength: 7,
        inputMode: "numeric",
        switchText: "Use a recovery code instead",
      };
}

// The body of the second request. Spaces are dropped; a recovery code keeps
// its dash (the panel ignores it either way).
export function secondFactorBody(ticket, recovery, text) {
  const value = String(text || "").replace(/\s+/g, "");
  return recovery ? { ticket, recovery: value } : { ticket, code: value };
}

// A ticket that is gone: the person starts again with the password. A wrong
// code (401 "wrong code") leaves the ticket for another try.
export function ticketIsGone(err) {
  return Boolean(err && err.status === 401 && !/wrong code/i.test(err.message || "")) || Boolean(err && err.status === 429);
}
