// The Account screen: who is signed in, the own password, and (with the
// permission users.manage) the users of the panel: add, change the role,
// disable, remove. Nothing here decides what a user may do; the panel does,
// the screen only hides what would answer 403.

// The permission that a screen needs to be of any use (nav entries only).
export const VIEW_PERM = { configs: "configs.edit", audit: "audit.view", backups: "backup.manage" };

export function visibleViews(views, perms) {
  return views.filter((v) => !VIEW_PERM[v] || perms.includes(VIEW_PERM[v]));
}

// The sentence for a refusal of the panel: it names the missing permission.
export function refusal(body) {
  if (body && body.error === "forbidden") {
    return "Your account may not do this" + (body.permission ? " (it needs the permission " + body.permission + ")" : "") + ".";
  }
  return "";
}

// The words of the two factor section.
export function twoFactorText(on) {
  return on
    ? "Two factor sign in is on: after the password you enter a code from your authenticator app."
    : "Two factor sign in is off. With it, the password alone does not sign anyone in.";
}

// The recovery codes as the text that is shown and copied: one per line.
export function recoveryText(codes) {
  return (Array.isArray(codes) ? codes : []).join("\n");
}

// What a person types into a code field: spaces around and inside are dropped.
export function cleanCode(text) {
  return String(text || "").replace(/\s+/g, "");
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function option(value, text) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = text;
  return o;
}

export function start(api, els, onError, me) {
  let running = true;

  function say(text, isError) {
    els.error.textContent = isError ? text : "";
    els.message.textContent = isError ? "" : text;
  }

  async function run(fn) {
    try {
      await fn();
    } catch (err) {
      if (err.status === 401) return onError(err);
      say(err.message, true);
      return false;
    }
    return true;
  }

  els.who.textContent = me.name + " (" + me.role + ")";

  els.passwordForm.onsubmit = async (event) => {
    event.preventDefault();
    if (!confirm("Change your password? You will have to sign in again.")) return;
    const ok = await run(() =>
      api("/api/me/password", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ current: els.current.value, new: els.next.value }),
      }),
    );
    if (ok) onError({ status: 401 });
  };

  // Two factor sign in of the own account. The panel keeps nothing until the
  // first code proves that the app has the secret; the recovery codes are
  // shown once and are not kept here after "I have saved them".
  let on = Boolean(me.two_factor);
  const post = (path, body) =>
    api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

  function showTwoFactor() {
    els.tfStatus.textContent = twoFactorText(on);
    els.tfStart.hidden = on || !els.tfSetup.hidden;
    els.tfManage.hidden = !on || !els.tfCodes.hidden;
  }

  function showCodes(codes) {
    els.tfCodeList.textContent = recoveryText(codes);
    els.tfCodes.hidden = false;
    els.tfManage.hidden = true;
  }

  els.tfStart.onsubmit = async (event) => {
    event.preventDefault();
    let res;
    const ok = await run(async () => {
      res = await post("/api/me/totp/setup", { password: els.tfStartPassword.value });
    });
    if (!ok) return;
    els.tfStartPassword.value = "";
    els.tfQr.src = res.qr || "";
    els.tfQr.hidden = !res.qr;
    els.tfSecret.textContent = res.secret;
    els.tfSetup.hidden = false;
    els.tfStart.hidden = true;
    els.tfConfirmCode.focus();
  };

  els.tfConfirm.onsubmit = async (event) => {
    event.preventDefault();
    let res;
    const ok = await run(async () => {
      res = await post("/api/me/totp/enable", { code: cleanCode(els.tfConfirmCode.value) });
    });
    if (!ok) return;
    on = true;
    els.tfConfirmCode.value = "";
    els.tfSecret.textContent = "";
    els.tfQr.src = "";
    els.tfSetup.hidden = true;
    showCodes(res.recovery);
    showTwoFactor();
    say("Two factor sign in is on. Save the recovery codes now.", false);
  };

  els.tfManage.onsubmit = async (event) => {
    event.preventDefault();
    if (!confirm("Turn off two factor sign in? Your other sessions end.")) return;
    const ok = await run(() => post("/api/me/totp/disable", { password: els.tfPassword.value, code: cleanCode(els.tfCode.value) }));
    if (!ok) return;
    on = false;
    els.tfPassword.value = "";
    els.tfCode.value = "";
    showTwoFactor();
    say("Two factor sign in is off.", false);
  };

  els.tfNewCodes.onclick = async () => {
    if (!confirm("Make new recovery codes? The old ones stop working.")) return;
    let res;
    const ok = await run(async () => {
      res = await post("/api/me/totp/recovery", { password: els.tfPassword.value, code: cleanCode(els.tfCode.value) });
    });
    if (!ok) return;
    els.tfPassword.value = "";
    els.tfCode.value = "";
    showCodes(res.recovery);
    say("New recovery codes. The old ones no longer work.", false);
  };

  els.tfCopy.onclick = async () => {
    try {
      await navigator.clipboard.writeText(els.tfCodeList.textContent);
      say("Recovery codes copied.", false);
    } catch {
      say("Could not copy: select the codes and copy them by hand.", true);
    }
  };

  els.tfSaved.onclick = () => {
    els.tfCodeList.textContent = "";
    els.tfCodes.hidden = true;
    showTwoFactor();
  };

  showTwoFactor();

  const manage = me.perms.includes("users.manage");
  els.manage.hidden = !manage;
  if (!manage) return () => (running = false);

  let catalog = { roles: [], permissions: [] };

  function permBoxes(selected) {
    const box = el("span", "perms");
    for (const p of catalog.permissions) {
      const label = el("label", "perm");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.value = p;
      input.checked = selected.includes(p);
      label.append(input, " " + p);
      box.append(label);
    }
    return box;
  }

  const chosen = (box) => [...box.querySelectorAll("input:checked")].map((i) => i.value);

  function row(u) {
    const tr = el("tr");
    const role = document.createElement("select");
    role.append(...catalog.roles.map((r) => option(r, r)));
    role.value = u.role;
    role.setAttribute("aria-label", "Role of " + u.name);
    const boxes = permBoxes(u.perms);
    boxes.hidden = u.role !== "custom";
    role.onchange = () => (boxes.hidden = role.value !== "custom");
    const save = el("button", "", "Save role");
    save.type = "button";
    save.onclick = async () => {
      if (!confirm("Change the role of " + u.name + " to " + role.value + "? Their sessions end.")) return;
      if (await run(() => change(u.name, { role: role.value, perms: role.value === "custom" ? chosen(boxes) : [] }))) await load();
    };
    const toggle = el("button", "", u.disabled ? "Enable" : "Disable");
    toggle.type = "button";
    toggle.disabled = u.name === me.name;
    toggle.onclick = async () => {
      if (!confirm((u.disabled ? "Enable " : "Disable ") + u.name + "?")) return;
      if (await run(() => change(u.name, { disabled: !u.disabled }))) await load();
    };
    const remove = el("button", "", "Remove");
    remove.type = "button";
    remove.disabled = u.name === me.name;
    remove.onclick = async () => {
      if (!confirm("Remove the user " + u.name + "? This cannot be undone.")) return;
      if (await run(() => api("/api/users/" + encodeURIComponent(u.name), { method: "DELETE" }))) await load();
    };
    const pw = document.createElement("input");
    pw.type = "password";
    pw.autocomplete = "new-password";
    pw.placeholder = "new password";
    pw.setAttribute("aria-label", "New password of " + u.name);
    const setPw = el("button", "", "Set password");
    setPw.type = "button";
    setPw.onclick = async () => {
      if (!pw.value) return;
      if (!confirm("Set a new password for " + u.name + "? Their sessions end.")) return;
      if (await run(() => change(u.name, { password: pw.value }))) {
        pw.value = "";
        say("Password of " + u.name + " changed.", false);
      }
    };
    const tf = el("td", "", u.two_factor ? "on" : "off");
    const resetTf = el("button", "", "Reset two factor");
    resetTf.type = "button";
    resetTf.hidden = !u.two_factor;
    resetTf.onclick = async () => {
      if (!confirm("Turn off two factor sign in of " + u.name + "? Their sessions end; they can set it up again.")) return;
      if (await run(() => api("/api/users/" + encodeURIComponent(u.name) + "/totp/reset", { method: "POST" }))) {
        say("Two factor sign in of " + u.name + " is off.", false);
        await load();
      }
    };
    const name = el("td", "", u.name + (u.disabled ? " (disabled)" : ""));
    const rcell = el("td");
    rcell.append(role, boxes);
    const pcell = el("td");
    pcell.append(pw, setPw);
    const acell = el("td");
    acell.append(save, toggle, resetTf, remove);
    tr.append(name, rcell, pcell, tf, acell);
    return tr;
  }

  const change = (name, body) =>
    api("/api/users/" + encodeURIComponent(name), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

  async function load() {
    if (!running) return;
    const res = await api("/api/users").catch((err) => {
      if (err.status === 401) onError(err);
      else say(err.message, true);
      return null;
    });
    if (!res || !running) return;
    catalog = res;
    els.newRole.replaceChildren(...res.roles.map((r) => option(r, r)));
    els.newPerms.replaceChildren(...res.permissions.map((p) => {
      const label = el("label", "perm");
      const input = document.createElement("input");
      input.type = "checkbox";
      input.value = p;
      label.append(input, " " + p);
      return label;
    }));
    els.newPerms.hidden = els.newRole.value !== "custom";
    const t = el("table");
    const head = el("tr");
    for (const h of ["User", "Role", "Password", "Two factor", ""]) head.append(el("th", "", h));
    t.append(head);
    for (const u of res.users) t.append(row(u));
    els.list.replaceChildren(t);
  }

  els.newRole.onchange = () => (els.newPerms.hidden = els.newRole.value !== "custom");
  els.add.onsubmit = async (event) => {
    event.preventDefault();
    const body = {
      name: els.newName.value.trim(),
      role: els.newRole.value,
      perms: chosen(els.newPerms),
      password: els.newPassword.value,
    };
    if (!confirm("Add the user " + body.name + " with the role " + body.role + "?")) return;
    const ok = await run(() =>
      api("/api/users", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
    );
    if (ok) {
      els.newName.value = "";
      els.newPassword.value = "";
      say("User " + body.name + " added.", false);
      await load();
    }
  };
  load();
  return () => (running = false);
}
