import { start as startOverview } from "./modules/overview.js";
import { start as startComponents } from "./modules/components.js";
import { start as startConfigs } from "./modules/configs.js";
import { start as startRules } from "./modules/rules.js";
import { start as startLogs } from "./modules/logs.js";
import { start as startEvents } from "./modules/events.js";
import { start as startMetrics } from "./modules/metrics.js";
import { start as startTests } from "./modules/tests.js";
import { start as startAlerts } from "./modules/alerts.js";
import { start as startIfaces } from "./modules/ifaces.js";
import { start as startMode } from "./modules/mode.js";
import { start as startNetwork } from "./modules/network.js";
import { start as startIps } from "./modules/ips.js";
import { start as startAlertCenter } from "./modules/alertcenter.js";
import { start as startTraffic } from "./modules/traffic.js";
import { start as startRules2 } from "./modules/rules2.js";
import { start as startExceptions } from "./modules/exceptions.js";
import * as topbar from "./modules/topbar.js";
import { start as startSettings } from "./modules/settings.js";
import * as account from "./modules/account.js";
import * as security from "./modules/security.js";
import { start as startAudit } from "./modules/audit.js";
import { start as startBackups } from "./modules/backups.js";
import * as shell from "./modules/shell.js";
import { start as startVersion } from "./modules/version.js";
import { menu, revealOnce, skipLink } from "./modules/chrome.js";

const REPO_URL = "https://github.com/FlexEbat/dpistack";
const $ = (id) => document.getElementById(id);

function cookie(name) {
  const hit = document.cookie.split("; ").find((c) => c.startsWith(name + "="));
  return hit ? decodeURIComponent(hit.slice(name.length + 1)) : "";
}

async function api(path, options = {}) {
  const headers = { ...options.headers };
  if (options.method && options.method !== "GET") {
    headers["X-CSRF-Token"] = cookie("dpistack_csrf");
  }
  const res = await fetch(path, { ...options, headers });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body.error || "Error " + res.status);
    err.status = res.status;
    err.body = body; // a refusal carries the checker's words in body.output
    if (res.status === 403) err.message = account.refusal(body) || err.message;
    throw err;
  }
  return body;
}

function show(id) {
  $("login").hidden = id !== "login";
  $("overview").hidden = id !== "overview";
}

const VIEWS = ["overview", "network", "traffic", "components", "ips", "settings", "configs", "rules", "exceptions", "logs", "events", "metrics", "tests", "alerts", "audit", "security", "backups", "account"];
let me = { name: "", role: "", perms: ["view"] };
let stopView = null;

// Every screen starts when shown and returns a stop function, so a hidden
// screen polls nothing and holds no stream.
const SCREENS = {
  overview: () =>
    startOverview(
      api,
      { overall: $("overall"), mix: $("components-mix"), components: $("components"), checks: $("checks"), error: $("overview-error"), hostBox: $("host-box"), host: $("host"), ifaces: $("host-ifaces"), glanceBox: $("glance-box"), cards: $("glance-cards"), warnings: $("glance-warnings"), alertsBox: $("alerts-box"), severity: $("alerts-severity"), recent: $("alerts-recent"), trafficBox: $("traffic-box"), traffic: $("traffic") },
      showLogin,
    ),
  components: () => {
    const stopList = startComponents(
      api,
      { list: $("components-list"), error: $("components-error"), message: $("components-message") },
      showLogin,
    );
    const stopIfaces = startIfaces(
      api,
      {
        root: $("ifaces"),
        error: $("ifaces-error"),
        message: $("ifaces-message"),
        list: $("ifaces-list"),
        name: $("ifaces-name"),
        add: $("ifaces-add"),
      },
      showLogin,
    );
    const stopMode = startMode(
      api,
      {
        error: $("mode-error"),
        status: $("mode-status"),
        message: $("mode-message"),
        ips: $("mode-ips"),
        ids: $("mode-ids"),
        confirm: $("mode-confirm"),
      },
      showLogin,
    );
    return () => {
      stopList();
      stopIfaces();
      stopMode();
    };
  },
  settings: () =>
    startSettings(
      api,
      {
        root: $("view-settings"),
        error: $("settings-error"),
        message: $("settings-message"),
        result: $("settings-result"),
        groups: $("settings-groups"),
        count: $("settings-count"),
        advanced: $("settings-advanced"),
        check: $("settings-check"),
        apply: $("settings-apply"),
        revert: $("settings-revert"),
        jobBox: $("settings-job-box"),
        job: $("settings-job"),
        search: $("settings-search"),
        cats: $("settings-cats"),
        details: $("settings-details"),
        diff: $("settings-diff"),
        profiles: $("settings-profiles"),
        profileName: $("settings-profile-name"),
        profileSave: $("settings-profile-save"),
        profileSaveAll: $("settings-profile-save-all"),
      },
      showLogin,
    ),
  configs: () =>
    startConfigs(
      api,
      {
        name: $("cfg-name"),
        editor: $("cfg-editor"),
        check: $("cfg-check"),
        save: $("cfg-save"),
        apply: $("cfg-apply"),
        revert: $("cfg-revert"),
        result: $("cfg-result"),
      },
      showLogin,
    ),
  rules: () => {
    const stopRules = startRules(
      api,
      {
        root: $("view-rules"),
        error: $("rules-error"),
        message: $("rules-message"),
        update: $("rules-update"),
        last: $("rules-last"),
        updateOutput: $("rules-update-output"),
        sources: $("rules-sources"),
        url: $("rules-url"),
        urlAdd: $("rules-url-add"),
        groups: $("rules-groups"),
        group: $("rules-group"),
        groupAdd: $("rules-group-add"),
        q: $("rules-q"),
        search: $("rules-search"),
        results: $("rules-results"),
        disabled: $("rules-disabled"),
      },
      showLogin,
    );
    const stopRules2 = startRules2(
      api,
      {
        error: $("rules-error"), message: $("rules-message"), stats: $("r2-stats"), history: $("r2-history"),
        class: $("r2-class"), source: $("r2-source"), state: $("r2-state"), text: $("r2-text"), find: $("r2-find"),
        findNote: $("r2-find-note"), findResults: $("r2-find-results"),
        editor: $("r2-editor"), reload: $("r2-reload"), check: $("r2-check"), save: $("r2-save"), apply: $("r2-apply"),
        report: $("r2-report"), versions: $("r2-versions"), diff: $("r2-diff"),
      },
      showLogin,
    );
    return () => {
      stopRules();
      stopRules2();
    };
  },
  logs: () =>
    startLogs(
      api,
      {
        component: $("log-component"),
        lines: $("log-lines"),
        show: $("log-show"),
        follow: $("log-follow"),
        output: $("log-output"),
        error: $("logs-error"),
      },
      showLogin,
    ),
  tests: () =>
    startTests(
      api,
      { error: $("tests-error"), buttons: $("tests-buttons"), note: $("tests-note"), result: $("tests-result") },
      showLogin,
    ),
  ips: () =>
    startIps(
      api,
      { error: $("ips-error"), summary: $("ips-summary"), checks: $("ips-checks"), counters: $("ips-counters"), rules: $("ips-rules"), blocked: $("ips-blocked"), sids: $("ips-sids"), run: $("ips-run"), note: $("ips-test-note"), result: $("ips-test-result") },
      showLogin,
    ),
  network: () =>
    startNetwork(api, { error: $("network-error"), topology: $("network-topology"), others: $("network-others"), ifaces: $("network-ifaces") }, showLogin),
  exceptions: () =>
    startExceptions(
      api,
      {
        error: $("exc-error"), message: $("exc-message"), summary: $("exc-summary"), hint: $("exc-hint"), list: $("exc-list"),
        kind: $("exc-kind"), sid: $("exc-sid"), scope: $("exc-scope"), scopeBox: $("exc-scope-box"), side: $("exc-side"), sideBox: $("exc-side-box"),
        ip: $("exc-ip"), ipBox: $("exc-ip-box"), count: $("exc-count"), countBox: $("exc-count-box"), seconds: $("exc-seconds"), secondsBox: $("exc-seconds-box"),
        expiry: $("exc-expiry"), days: $("exc-days"), daysBox: $("exc-days-box"), note: $("exc-note"), add: $("exc-add"),
      },
      showLogin,
    ),
  traffic: () =>
    startTraffic(
      api,
      { error: $("traffic-error"), notes: $("traffic-notes"), tabs: $("traffic-tabs"), text: $("traffic-q"), external: $("traffic-external"), detail: $("traffic-detail"), body: $("traffic-body") },
      showLogin,
    ),
  alerts: () => {
    const center = startAlertCenter(
      api,
      { error: $("ac-error"), summary: $("ac-summary"), state: $("ac-state"), source: $("ac-source"), severity: $("ac-severity"), note: $("ac-note"), refresh: $("ac-refresh"), list: $("ac-list"), history: $("ac-history") },
      showLogin,
      me.perms.includes("events.ack"),
    );
    const feed = startAlerts(
      api,
      { error: $("alerts-error"), check: $("al-check"), limit: $("al-limit"), refresh: $("al-refresh"), list: $("al-list") },
      showLogin,
    );
    return () => {
      center();
      feed();
    };
  },
  audit: () =>
    startAudit(
      api,
      {
        error: $("audit-error"),
        form: $("audit-form"),
        user: $("audit-user"),
        action: $("audit-action"),
        result: $("audit-result"),
        since: $("audit-since"),
        limit: $("audit-limit"),
        csv: $("audit-csv"),
        json: $("audit-json"),
        list: $("audit-list"),
      },
      showLogin,
    ),
  backups: () =>
    startBackups(
      api,
      {
        error: $("backups-error"),
        message: $("backups-message"),
        create: $("backups-create"),
        result: $("backups-result"),
        list: $("backups-list"),
      },
      showLogin,
    ),
  security: () =>
    security.start(
      api,
      {
        error: $("sec-error"),
        message: $("sec-message"),
        checkBox: $("sec-check-box"),
        checkSummary: $("sec-check-summary"),
        checkList: $("sec-check-list"),
        run: $("sec-run"),
        sessions: $("sec-sessions"),
        endOthers: $("sec-others"),
        signOutAll: $("sec-signout-all"),
        tokens: $("sec-tokens"),
        tokenAllBox: $("sec-token-all-box"),
        tokenAll: $("sec-token-all"),
        tokenName: $("sec-token-name"),
        tokenScope: $("sec-token-scope"),
        tokenDays: $("sec-token-days"),
        tokenCreate: $("sec-token-create"),
        secretBox: $("sec-secret-box"),
        secret: $("sec-secret"),
        secretNote: $("sec-secret-note"),
        secretCopy: $("sec-secret-copy"),
        secretHide: $("sec-secret-hide"),
        logins: $("sec-logins"),
        loginScopeBox: $("sec-login-scope-box"),
        loginScope: $("sec-login-scope"),
      },
      showLogin,
      me.perms,
    ),
  account: () =>
    account.start(
      api,
      {
        error: $("account-error"),
        message: $("account-message"),
        who: $("account-who"),
        passwordForm: $("account-password"),
        current: $("account-current"),
        next: $("account-next"),
        manage: $("account-manage"),
        list: $("account-list"),
        add: $("account-add"),
        newName: $("account-new-name"),
        newRole: $("account-new-role"),
        newPerms: $("account-new-perms"),
        newPassword: $("account-new-password"),
      },
      showLogin,
      me,
    ),
  metrics: () =>
    startMetrics(
      api,
      { error: $("metrics-error"), ranges: $("mx-ranges"), charts: $("mx-charts") },
      showLogin,
    ),
  events: () =>
    startEvents(
      api,
      {
        error: $("events-error"),
        type: $("ev-type"),
        q: $("ev-q"),
        limit: $("ev-limit"),
        show: $("ev-show"),
        follow: $("ev-follow"),
        list: $("ev-list"),
        range: $("ev-range"),
        ip: $("ev-ip"),
        sid: $("ev-sid"),
        category: $("ev-category"),
        proto: $("ev-proto"),
        severity: $("ev-severity"),
        domain: $("ev-domain"),
        group: $("ev-group"),
        exportJSON: $("ev-export-json"),
        exportCSV: $("ev-export-csv"),
        status: $("ev-status"),
      },
      showLogin,
    ),
};

let current = "";

function showView(name) {
  current = name;
  if (location.hash !== shell.hashOf(name)) location.hash = shell.hashOf(name);
  const btn = document.querySelector(`#nav button[data-view="${name}"]`);
  if (btn) $("page-title").textContent = btn.textContent.trim();
  show("overview"); // the signed-in page
  stopView?.();
  for (const v of VIEWS) $("view-" + v).hidden = v !== name;
  for (const b of document.querySelectorAll("#nav button[data-view]")) {
    if (b.dataset.view === name) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  }
  stopView = SCREENS[name]();
}

let stopVersion = null;
let stopTop = null;

async function showOverview() {
  // Who is signed in decides which entries of the menu are shown.
  me = await api("/api/me").catch(() => me);
  for (const b of document.querySelectorAll("#nav button[data-view]")) {
    b.hidden = !account.visibleViews([b.dataset.view], me.perms).length;
  }
  shell.syncGroups(document);
  // The address names the screen; one the user may not use opens Overview.
  const wanted = shell.viewFromHash(location.hash, VIEWS);
  const allowed = wanted && account.visibleViews([wanted], me.perms).length;
  showView(allowed ? wanted : "overview");
  // The corner: the version, and the update when there is one.
  // The repository links are set here, so the page itself carries no external address.
  for (const a of document.querySelectorAll("a[data-repo]")) {
    a.href = REPO_URL + (a.dataset.repo ? "/" + a.dataset.repo : "");
  }
  const note = $("translate-note");
  $("translate-btn").onclick = () => {
    note.hidden = !note.hidden;
    if (!note.hidden) setTimeout(() => (note.hidden = true), 2500);
  };
  // The top bar: the name of the signed-in user, and the host, state and mode chips.
  $("user-name").textContent = me.name || "User";
  $("user-account").hidden = !account.visibleViews(["account"], me.perms).length;
  stopTop?.();
  stopTop = topbar.start(api, { host: $("top-host"), state: $("top-state"), mode: $("top-mode"), bell: $("top-bell") }, showLogin);
  stopVersion?.();
  stopVersion = startVersion(api, {
    badge: $("version-badge"),
    badgeText: $("version-text"),
    banner: $("update-banner"),
    facts: $("build-facts"),
    close: $("update-close"),
    dialog: $("update-dialog"),
    text: $("update-text"),
    status: $("update-status"),
    log: $("update-log"),
    yes: $("update-yes"),
    no: $("update-no"),
  });
}

function showLogin() {
  stopVersion?.();
  stopVersion = null;
  stopTop?.();
  stopTop = null;
  stopView?.();
  stopView = null;
  show("login");
  $("password").value = "";
  $("password").focus();
}

async function boot() {
  try {
    await api("/api/status");
    showOverview();
  } catch (err) {
    if (err.status === 401) {
      showLogin();
    } else {
      showOverview(); // the screen shows the error text itself
    }
  }
}

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("login-error").textContent = "";
  try {
    await api("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: $("username").value.trim(), password: $("password").value }),
    });
    $("password").value = "";
    await boot();
  } catch (err) {
    $("login-error").textContent = err.message;
  }
});

const navMenu = menu();
for (const b of document.querySelectorAll("#nav button[data-view]")) {
  b.addEventListener("click", () => {
    showView(b.dataset.view);
    navMenu.close();
  });
}
skipLink();
revealOnce(document);
let store = { getItem: () => null, setItem() {} };
try {
  store = window.localStorage; // some browsers refuse even the property
} catch {
  // the menu then starts expanded every time
}
shell.collapse(document, store);
window.addEventListener("hashchange", () => {
  const name = shell.viewFromHash(location.hash, VIEWS);
  if (!name || name === current || $("overview").hidden) return;
  if (!account.visibleViews([name], me.perms).length) return showView("overview");
  showView(name);
});

const userMenu = topbar.userMenu(document);
$("user-account").addEventListener("click", () => {
  userMenu.close();
  showView("account");
});

$("logout").addEventListener("click", async () => {
  userMenu.close();
  await api("/api/logout", { method: "POST" }).catch(() => {});
  showLogin();
});

boot();
