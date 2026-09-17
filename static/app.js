const listEl = document.getElementById("list");
const emptyEl = document.getElementById("empty");
const filterEl = document.getElementById("filter");
const clearEl = document.getElementById("clear");
const idleEl = document.getElementById("idle");
const detailEl = document.getElementById("detail");
const dLine = document.getElementById("d-line");
const dSub = document.getElementById("d-sub");
const dReq = document.getElementById("d-req");
const dRes = document.getElementById("d-res");

let selected = null;
let timer = null;

function fmtTime(ts) {
  const d = new Date(Number(ts) * 1000);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString();
}

function fmtListTime(ts) {
  const d = new Date(Number(ts) * 1000);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
    month: "2-digit",
    day: "2-digit",
  });
}

function pretty(text) {
  if (!text) return "";
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

function headersBlock(raw) {
  let obj = raw;
  if (typeof raw === "string") {
    try { obj = JSON.parse(raw); } catch { return raw; }
  }
  if (!obj || typeof obj !== "object") return "";
  return Object.entries(obj)
    .map(([k, v]) => `${k}: ${v}`)
    .join("\n");
}

function statusClass(status) {
  if (status >= 500) return "is-fault";
  if (status >= 400) return "is-client";
  if (status >= 200) return "is-ok";
  return "";
}

async function loadMeta() {
  const res = await fetch("/_audit/meta");
  if (!res.ok) return;
  const meta = await res.json();
  document.getElementById("meta-listen").textContent = meta.listen;
  document.getElementById("meta-upstream").textContent = meta.upstream;
}

async function loadLicense() {
  const box = document.getElementById("license");
  const pre = document.getElementById("license-text");
  const res = await fetch("/_audit/license");
  if (!res.ok) return;
  const info = await res.json();
  if (info.agreed) {
    box.hidden = true;
    return;
  }
  box.hidden = false;
  pre.textContent = info.text || info.status || "";
}

async function loadList() {
  const q = filterEl.value.trim();
  const url = q ? `/_audit/calls?q=${encodeURIComponent(q)}` : "/_audit/calls";
  const res = await fetch(url);
  if (!res.ok) return;
  const data = await res.json();
  const calls = data.calls || [];
  emptyEl.hidden = calls.length > 0;
  listEl.replaceChildren();
  for (const call of calls) {
    const li = document.createElement("li");
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `row ${statusClass(call.status)}`;
    if (call.id === selected) btn.classList.add("is-on");
    const method = document.createElement("span");
    method.className = "method";
    method.textContent = call.method;
    const path = document.createElement("span");
    path.className = "path";
    path.textContent = call.path;
    const ms = document.createElement("span");
    ms.className = "ms";
    ms.textContent = `${call.status ?? "—"}  ${call.duration_ms ?? "—"}ms`;
    const when = document.createElement("span");
    when.className = "when";
    when.textContent = fmtListTime(call.ts);
    btn.append(when, method, path, ms);
    btn.addEventListener("click", () => openCall(call.id));
    li.appendChild(btn);
    listEl.appendChild(li);
  }
}

async function openCall(id) {
  selected = id;
  const res = await fetch(`/_audit/calls/${id}`);
  if (!res.ok) return;
  const call = await res.json();
  idleEl.hidden = true;
  detailEl.hidden = false;
  dLine.textContent = `${call.method} ${call.path}`;
  dSub.textContent = `${fmtTime(call.ts)}  status ${call.status ?? "none"}  ${call.duration_ms ?? "—"} ms${call.error ? "  " + call.error : ""}`;
  const reqHead = headersBlock(call.req_headers);
  const resHead = headersBlock(call.res_headers);
  dReq.textContent = [reqHead, pretty(call.req_body)].filter(Boolean).join("\n\n");
  dRes.textContent = [resHead, pretty(call.res_body)].filter(Boolean).join("\n\n");
  await loadList();
}

clearEl.addEventListener("click", async () => {
  await fetch("/_audit/calls", { method: "DELETE" });
  selected = null;
  idleEl.hidden = false;
  detailEl.hidden = true;
  await loadList();
});

filterEl.addEventListener("input", () => {
  loadList();
});

loadMeta();
loadLicense();
loadList();
timer = setInterval(loadList, 1500);
setInterval(loadLicense, 4000);
if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  clearInterval(timer);
}
