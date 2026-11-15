// Templates for the custom rules (local.rules): a rule with its text filled in,
// and a description that says what it matches, what to change and what to
// expect. The sid is the next free one of the range Suricata keeps for local
// rules; the panel check still looks at the whole file before it is saved.

export const SID_MIN = 9000000;
export const SID_MAX = 9999999;
const SID_FIRST = 9001000; // clear of the sids the installer uses for its own test rules

export const TEMPLATES = [
  {
    id: "dns-domain",
    title: "DNS query for a domain",
    summary: "Alert when a host asks for a name",
    description:
      "Matches every DNS query whose name contains the text you put in content, for example a domain of a known malware family or a site that is not allowed on this network. It looks at the question, so it fires even when the answer is blocked or fails. The match is not case sensitive and also hits subdomains (\"example.org\" matches \"www.example.org\"). Change the domain and the message. Works in IDS and IPS mode, and DNS over HTTPS or TLS is not seen by it.",
    rule: 'alert dns $HOME_NET any -> any any (msg:"dpistack custom: DNS query for example.org"; dns.query; content:"example.org"; nocase; classtype:bad-unknown; sid:@SID@; rev:1;)',
  },
  {
    id: "tls-sni",
    title: "TLS connection to a site name",
    summary: "Alert on the server name of an HTTPS connection",
    description:
      "Matches the server name (SNI) that a client sends at the start of a TLS connection, so it names the site even though the traffic is encrypted. Use it to watch or to flag access to a service, for example a file sharing site or a command and control domain. Change the name in content. A client that hides the name (encrypted client hello) is not matched. In IPS mode, change alert to drop to cut the connection.",
    rule: 'alert tls $HOME_NET any -> any any (msg:"dpistack custom: TLS to example.org"; tls.sni; content:"example.org"; nocase; classtype:policy-violation; sid:@SID@; rev:1;)',
  },
  {
    id: "http-user-agent",
    title: "HTTP User-Agent string",
    summary: "Alert on a program that names itself in a request",
    description:
      "Matches a plain HTTP request whose User-Agent header contains the text. Many scripts, scanners and old malware use a fixed or unusual agent, so this is a cheap way to spot them. Change the text in content (the example is the default agent of curl). It does not see HTTPS: the header is inside the encryption. A false hit is likely on a short text, so use a text that is specific.",
    rule: 'alert http $HOME_NET any -> any any (msg:"dpistack custom: HTTP User-Agent curl"; http.user_agent; content:"curl/"; startswith; classtype:misc-activity; sid:@SID@; rev:1;)',
  },
  {
    id: "ip-alert",
    title: "Traffic to an address",
    summary: "Alert on any connection to one IP address",
    description:
      "Matches every packet from the home network to one address, in any protocol. Use it for an address from a report or a block list. Change the address (a list in square brackets, [203.0.113.10,203.0.113.11], and a network such as 203.0.113.0/24 also work). Both the first packet and the rest of the flow count, so one connection can raise more than one alert. Keep a list on a reputation feed for addresses that change often.",
    rule: 'alert ip $HOME_NET any -> 203.0.113.10 any (msg:"dpistack custom: traffic to 203.0.113.10"; classtype:trojan-activity; sid:@SID@; rev:1;)',
  },
  {
    id: "ip-drop",
    title: "Block traffic to an address",
    summary: "Drop the packets to one IP address (IPS mode)",
    description:
      "Same match as the address alert, but the action is drop: the packets are not forwarded. This works only when Suricata runs as IPS (Components, Suricata mode) and the traffic really passes through it. In IDS mode the rule is loaded and the drop is shown as an alert that says what would have been dropped, so it is safe to try there first. Change the address before you save.",
    rule: 'drop ip $HOME_NET any -> 203.0.113.10 any (msg:"dpistack custom: block traffic to 203.0.113.10"; classtype:trojan-activity; sid:@SID@; rev:1;)',
  },
  {
    id: "ssh-bruteforce",
    title: "Many SSH connection attempts",
    summary: "Alert when one source opens SSH connections too fast",
    description:
      "Counts the first packets (SYN) of new connections to port 22 and raises one alert when a single source address makes 5 of them within 60 seconds, which is the pattern of a password guessing tool. Change count and seconds to fit your own network, and the port if SSH listens elsewhere. It sees the attempts, not whether a login worked. The alert repeats once for each period, not for each packet.",
    rule: 'alert tcp any any -> $HOME_NET 22 (msg:"dpistack custom: many SSH connection attempts"; flow:to_server; flags:S; threshold:type both, track by_src, count 5, seconds 60; classtype:attempted-admin; sid:@SID@; rev:1;)',
  },
  {
    id: "pass-host",
    title: "Ignore a trusted host",
    summary: "Stop the rules from firing for one address",
    description:
      "A pass rule tells Suricata to stop inspecting the traffic of one address, in both directions, so no other rule alerts for it and it is never dropped. Use it for a scanner or a backup server you run yourself that causes alerts you understand. Change the address. A pass rule takes the host out of every check, so keep the list short; to silence one rule only, disable that rule in Rules instead.",
    rule: 'pass ip 192.168.1.10 any <> any any (msg:"dpistack custom: ignore trusted host 192.168.1.10"; sid:@SID@; rev:1;)',
  },
];

// nextSid is the first sid after the highest local one in the text, or the
// first of the local range when there is none. Null when the range is full.
export function nextSid(text) {
  let top = SID_FIRST - 1;
  for (const m of String(text ?? "").matchAll(/\bsid\s*:\s*(\d+)\s*;/g)) {
    const n = Number(m[1]);
    if (n >= SID_MIN && n <= SID_MAX && n > top) top = n;
  }
  return top + 1 <= SID_MAX ? top + 1 : null;
}

// fill returns the rule of a template with a free sid, or null when the
// template is unknown or no sid is left.
export function fill(id, text) {
  const t = TEMPLATES.find((x) => x.id === id);
  const sid = nextSid(text);
  if (!t || sid === null) return null;
  return t.rule.replace("@SID@", String(sid));
}

// insertInto adds the rule at the end of the text on a line of its own, with a
// comment line above it that names the template.
export function insertInto(text, id) {
  const t = TEMPLATES.find((x) => x.id === id);
  const rule = fill(id, text);
  if (!t || rule === null) return null;
  const base = String(text ?? "").replace(/\s+$/, "");
  return `${base}${base ? "\n\n" : ""}# ${t.title}\n${rule}\n`;
}

export function start(els) {
  if (!els.select || !els.insert || !els.editor) return () => {};
  els.select.replaceChildren();
  const first = document.createElement("option");
  first.value = "";
  first.textContent = "Choose a template";
  els.select.append(first);
  for (const t of TEMPLATES) {
    const o = document.createElement("option");
    o.value = t.id;
    o.textContent = `${t.title}: ${t.summary}`;
    els.select.append(o);
  }
  function show() {
    const t = TEMPLATES.find((x) => x.id === els.select.value);
    els.desc.textContent = t ? t.description : "A template adds one rule at the end of the file with the next free sid. Change the values in it, then use Check.";
    els.preview.textContent = t ? t.rule.replace("@SID@", String(nextSid(els.editor.value) ?? "")) : "";
    els.preview.hidden = !t;
    els.insert.disabled = !t;
  }
  function insert() {
    const next = insertInto(els.editor.value, els.select.value);
    if (next === null) {
      els.desc.textContent = "The range of local sids is full: remove a rule you do not need first.";
      return;
    }
    els.editor.value = next;
    els.editor.dispatchEvent(new Event("input"));
    els.editor.focus();
    show();
  }
  els.select.addEventListener("change", show);
  els.insert.addEventListener("click", insert);
  show();
  return () => {
    els.select.removeEventListener("change", show);
    els.insert.removeEventListener("click", insert);
  };
}
