const listEl = document.getElementById("list");
const emptyEl = document.getElementById("empty");
const filterEl = document.getElementById("filter");
const clearEl = document.getElementById("clear");
const idleEl = document.getElementById("idle");
const detailEl = document.getElementById("detail");
const dLine = document.getElementById("d-line");
const dSub = document.getElementById("d-sub");
const dUsage = document.getElementById("d-usage");
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

function issueClass(issue) {
  if (issue === "ok") return "is-ok";
  if (issue === "guardrail" || issue === "context" || issue === "csrf" || issue === "invalid") {
    return "is-warn";
  }
  return "is-fault";
}

function tokText(call) {
  if (call.total_tokens == null) return "—";
  const p = call.prompt_tokens ?? "—";
  const c = call.completion_tokens ?? "—";
  return `${p}+${c}  ${call.total_tokens}`;
}

async function loadStatus() {
  const res = await fetch("/_audit/status");
  if (!res.ok) return;
  const info = await res.json();
  document.getElementById("meta-listen").textContent = info.listen;
  document.getElementById("meta-upstream").textContent = info.upstream;
  const license = info.license || {};
  document.getElementById("meta-license").textContent = license.agreed
    ? "agreed"
    : "not agreed";
  const model = info.model || {};
  if (!model.reachable) {
    document.getElementById("meta-model").textContent = "upstream down";
  } else if (model.available) {
    document.getElementById("meta-model").textContent = `${model.name || "system"} available`;
  } else {
    document.getElementById("meta-model").textContent = model.reason || "unavailable";
  }
  const pcc = model.pcc || {};
  const pccEl = document.getElementById("meta-pcc");
  if (pccEl) {
    if (pcc.state === "available") pccEl.textContent = "available";
    else if (pcc.state === "unsupported") pccEl.textContent = "unsupported (needs 27.2)";
    else if (pcc.state) pccEl.textContent = pcc.reason ? `${pcc.state}: ${pcc.reason}` : pcc.state;
    else pccEl.textContent = "…";
  }
  const box = document.getElementById("license");
  const pre = document.getElementById("license-text");
  if (license.agreed) {
    box.hidden = true;
  } else {
    box.hidden = false;
    pre.textContent = license.text || license.status || "";
  }
  const gate = document.getElementById("model-gate");
  const reason = document.getElementById("model-gate-reason");
  if (model.reachable && model.available) {
    gate.hidden = true;
  } else {
    gate.hidden = false;
    if (!model.reachable) {
      reason.textContent = `fm serve is not reachable at ${info.upstream}. ${model.reason || ""}`.trim();
    } else {
      reason.textContent = model.reason || "fm available returned unavailable.";
    }
  }
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
    const tag = document.createElement("span");
    tag.className = `tag ${issueClass(call.issue)}`;
    tag.textContent = call.issue && call.issue !== "ok" ? call.issue : "";
    const tok = document.createElement("span");
    tok.className = "tok";
    tok.textContent = tokText(call);
    btn.append(when, method, path, tag, tok, ms);
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
  dSub.textContent = `${fmtTime(call.ts)}  status ${call.status ?? "none"}  ${call.duration_ms ?? "—"} ms  ${call.issue && call.issue !== "ok" ? call.issue : ""}${call.error ? "  " + call.error : ""}`;
  dUsage.textContent = call.total_tokens == null
    ? "tokens  —"
    : `tokens  prompt ${call.prompt_tokens}  completion ${call.completion_tokens}  total ${call.total_tokens}`;
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

const btnFetchQuota = document.getElementById("btn-fetch-quota");
const quotaBadge = document.getElementById("quota-badge");
const quotaUpdated = document.getElementById("quota-updated");

function renderQuota(data) {
  if (!quotaBadge) return;
  const pcc = data.pcc || {};
  const quota = pcc.quota || {};
  const now = new Date();
  const timeStr = now.toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false
  });

  if (!pcc.available) {
    quotaBadge.className = "badge is-warn";
    quotaBadge.textContent = pcc.reason ? `PCC 不可用: ${pcc.reason}` : "PCC 不可用";
  } else if (quota.limit_reached) {
    quotaBadge.className = "badge is-fault";
    quotaBadge.textContent = "PCC 限额已满 (Limit Reached)";
  } else if (quota.approaching_limit) {
    quotaBadge.className = "badge is-warn";
    quotaBadge.textContent = "PCC 接近限额 (Approaching)";
  } else {
    quotaBadge.className = "badge is-ok";
    quotaBadge.textContent = "正常 (Normal)";
  }

  if (quotaUpdated) {
    let msg = `已更新 ${timeStr}`;
    if (quota.resets_at) {
      const rd = new Date(quota.resets_at);
      const rStr = Number.isNaN(rd.getTime()) ? String(quota.resets_at) : rd.toLocaleString();
      msg += ` (限额重置: ${rStr})`;
    }
    quotaUpdated.textContent = msg;
  }
}

async function fetchQuota() {
  if (!btnFetchQuota) return;
  btnFetchQuota.disabled = true;
  const btnText = btnFetchQuota.querySelector(".quota-btn-text");
  const origText = btnText ? btnText.textContent : "获取 Usage Limit";
  if (btnText) btnText.textContent = "正在获取...";

  try {
    const res = await fetch("/_audit/quota");
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    renderQuota(data);
  } catch (err) {
    if (quotaBadge) {
      quotaBadge.className = "badge is-fault";
      quotaBadge.textContent = "获取失败";
    }
    if (quotaUpdated) {
      quotaUpdated.textContent = err.message;
    }
  } finally {
    btnFetchQuota.disabled = false;
    if (btnText) btnText.textContent = origText;
  }
}

if (btnFetchQuota) {
  btnFetchQuota.addEventListener("click", fetchQuota);
}

loadStatus();
loadList();
fetchQuota();
timer = setInterval(loadList, 1500);
setInterval(loadStatus, 4000);
if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  clearInterval(timer);
}
