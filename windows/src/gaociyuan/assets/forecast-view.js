Object.assign(supplementalTranslations, {
  "额度可用性预测": "Quota availability forecast",
  "根据同一额度周期的本机历史快照估算。": "Estimated from local snapshots in the same quota cycle.",
  "风险清单": "Risk list",
  "实测额度": "Observed quotas",
  "实测剩余": "Observed remaining",
  "观测时间": "Observed at",
  "下次重置": "Next reset",
  "记录的重置时间": "Recorded reset",
  "预计用尽": "Estimated depletion",
  "预计重置前用尽": "Estimated to run out before reset",
  "预计可用至重置": "Expected to last until reset",
  "实测已用尽": "Observed as depleted",
  "数据不足": "Insufficient data",
  "未纳入预测": "Excluded from forecasts",
  "当前账户的预测": "Forecast for this account",
  "预测详情": "Forecast details",
  "实测": "Observed",
  "趋势估算": "Trend estimate",
  "估算依据": "Estimate basis",
  "置信度": "Confidence",
  "中等": "Moderate",
  "较高": "Higher",
  "样本": "Samples",
  "观测跨度": "Observation span",
  "观测速率": "Observed rate",
  "显示时区": "Display time zone",
  "账户已暂停。": "This account is paused.",
  "Grok Bot 的手动报告只保留最近一次读数，缺少连续的窗口样本。": "The manual Grok Bot report retains one reading, so it has no sequence of window samples.",
  "此账户没有可用于预测的周期百分比额度。": "This account has no measured percentage-based quota window.",
  "尚未观测到周期额度。": "A quota window has not been observed yet.",
  "缺少可用的额度重置时间。": "A usable quota reset time is missing.",
  "上次观测的额度周期已结束，等待新周期快照。": "The observed quota cycle ended. Waiting for a snapshot in the next cycle.",
  "最近一次观测已过时，请同步账户。": "The last observation is stale. Sync the account to continue.",
  "同一额度周期的有效快照不足。": "There are too few valid snapshots from the same quota cycle.",
  "样本中的用量变化太小，无法估算。": "The measured change is too small to estimate a trend.",
  "观测速率波动较大，无法估算。": "Observed rates vary too much to estimate a trend.",
  "预测跨度超出当前样本可支撑的范围。": "The projected period is too long for the available observations.",
  "同步未取得新读数，当前显示上次观测。": "The last sync returned no new quota reading. The previous observation is shown.",
  "预计用尽时间已到，刷新确认。": "Estimated depletion time has passed. Sync to confirm.",
  "凭证已失效，重新连接前不展示旧读数。": "The credential has expired. Reconnect this account to see quota readings.",
  "符合估算条件的额度窗中，未发现重置前用尽的风险。": "No eligible window is estimated to run out before reset.",
  "暂无可估算的额度窗口。": "No quota window can be estimated yet.",
  "接入支持周期额度的 Agent 后可以查看预测。": "Connect an Agent with quota windows to see forecasts.",
  "启用账户并获取周期额度后可以查看预测。": "Enable an account and collect a quota window to see forecasts.",
  "查看账户预测详情可了解各窗口的样本或排除原因。": "Account forecast details explain the available samples and exclusions for each window.",
  "后续使用速率变化时，预计时间会随新观测更新。": "Estimated times update as new observations reflect changes in usage.",
});

const forecastStatus = {
  risk: "预计重置前用尽",
  stable: "预计可用至重置",
  exhausted: "实测已用尽",
  insufficient: "数据不足",
  excluded: "未纳入预测",
};

const forecastReason = {
  disabled: "账户已暂停。",
  manualGrok: "Grok Bot 的手动报告只保留最近一次读数，缺少连续的窗口样本。",
  nonQuota: "此账户没有可用于预测的周期百分比额度。",
  noReadings: "尚未观测到周期额度。",
  unknownReset: "缺少可用的额度重置时间。",
  expired: "上次观测的额度周期已结束，等待新周期快照。",
  stale: "最近一次观测已过时，请同步账户。",
  insufficientHistory: "同一额度周期的有效快照不足。",
  lowChange: "样本中的用量变化太小，无法估算。",
  unstable: "观测速率波动较大，无法估算。",
  beyondEvidence: "预测跨度超出当前样本可支撑的范围。",
  syncIssue: "同步未取得新读数，当前显示上次观测。",
  estimatedPassed: "预计用尽时间已到，刷新确认。",
  credential: "凭证已失效，重新连接前不展示旧读数。",
};

const forecastConfidence = { moderate: "中等", higher: "较高" };

function accountForecast(account) {
  if (!account.quotaForecast || antigravityLegacyAccount(account)) return null;
  return credentialProblem(account)
    ? { status: "insufficient", reason: "credential", windows: [] }
    : account.quotaForecast;
}

function forecastWindows(forecast) {
  const windows = forecast?.windows;
  return Array.isArray(windows) ? windows : [];
}

function forecastRemaining(remaining) {
  return Number.isFinite(remaining) ? `${number(remaining)}%` : "—";
}

function forecastTime(value) {
  if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) return "—";
  return `<time datetime="${text(value)}">${text(displayDate(value, { year: "numeric" }))}</time>`;
}

function forecastDatum(label, html, highlight = false, note = "") {
  return `<div${highlight ? ' class="forecast-emphasis"' : ""}><dt>${t(label)}</dt><dd>${html}${
    note ? `<small class="forecast-metric-note">${note}</small>` : ""
  }</dd></div>`;
}

function forecastDetailButton(account, window = null) {
  const subject = window ? `${account.name} · ${window.title}` : account.name;
  const description = inEnglish() ? `${tr("预测详情")} for ${subject}` : `${subject}的预测详情`;
  return `<button type="button" class="forecast-detail-link" data-action="quota-forecast" data-value="${text(account.id)}"${
    window ? ` data-window="${text(window.id)}"` : ""
  } aria-label="${text(description)}">${t("预测详情")}${icon("chevron")}</button>`;
}

function forecastBadge(status) {
  const tone = status === "risk" ? "amber" : status === "exhausted" ? "red" : status === "stable" ? "teal" : "secondary";
  return tag(forecastStatus[status] || forecastStatus.insufficient, tone);
}

function forecastRiskRow(account, window) {
  const provider = providerFor(account.provider);
  const confidence = forecastConfidence[window.confidence];
  const basis = confidence ? `${t("置信度")} · ${t(confidence)}` : "";
  const note = window.reason === "estimatedPassed" ? [basis, t(forecastReason.estimatedPassed)].filter(Boolean).join("<br>") : basis;
  return `<li class="forecast-risk" data-account="${text(account.id)}" data-window="${text(window.id)}">
    <div class="marked">${providerMark(provider, 32)}<div class="stacked">
      <strong>${text(account.name)}</strong><span class="caption muted">${t(window.title)}</span>
    </div></div>
    <dl class="forecast-metrics">
      ${forecastDatum("实测剩余", text(forecastRemaining(window.remainingPercent)))}
      ${forecastDatum("预计用尽", forecastTime(window.estimatedExhaustedAt), true, note)}
      ${forecastDatum("下次重置", forecastTime(window.resetsAt))}
    </dl>
    ${forecastDetailButton(account, window)}
  </li>`;
}

function renderForecastOverview() {
  const active = activeAccounts();
  const windows = active.flatMap((account) => forecastWindows(accountForecast(account)).map((window) => ({ account, window })));
  const risks = windows.filter(({ window }) => window.status === "risk")
    .sort((left, right) => Date.parse(left.window.estimatedExhaustedAt) - Date.parse(right.window.estimatedExhaustedAt));
  const estimateCount = windows.filter(({ window }) => window.status === "risk" || window.status === "stable").length;
  const emptyDetail = active.length ? "查看账户预测详情可了解各窗口的样本或排除原因。"
    : accounts().length ? "启用账户并获取周期额度后可以查看预测。" : "接入支持周期额度的 Agent 后可以查看预测。";
  return `<section class="panel forecast-overview" id="quota-forecast" aria-labelledby="quota-forecast-title">
    <header class="section-heading"><div class="marked"><span class="forecast-symbol">${icon("chart")}</span><div class="stacked">
      <h2 id="quota-forecast-title">${t("额度可用性预测")}</h2><p class="caption muted">${t("根据同一额度周期的本机历史快照估算。")}</p>
    </div></div></header>
    <div class="forecast-risk-section">
      <div class="section-heading"><h3 id="forecast-risk-title">${t("风险清单")}</h3>
        ${risks.length ? `<span class="caption amber">${text(countText(risks.length, "个额度窗预计重置前用尽", "windows at risk"))}</span>` : ""}
      </div>
      ${risks.length ? `<ul class="forecast-risk-list" aria-labelledby="forecast-risk-title"${risks.length > 4 ? ' tabindex="0"' : ""}>
        ${risks.map(({ account, window }) => forecastRiskRow(account, window)).join("")}
      </ul>` : `<div class="forecast-empty muted">${icon("info")}<div class="stacked">
        <strong>${t(estimateCount ? "符合估算条件的额度窗中，未发现重置前用尽的风险。" : "暂无可估算的额度窗口。")}</strong>
        <p class="caption">${t(emptyDetail)}</p>
      </div></div>`}
    </div>
  </section>`;
}

function renderAccountForecast(account) {
  const forecast = accountForecast(account);
  if (!forecast) return "";
  const windows = forecastWindows(forecast);
  const risk = windows.filter((window) => window.status === "risk")
    .sort((left, right) => Date.parse(left.estimatedExhaustedAt) - Date.parse(right.estimatedExhaustedAt))[0];
  const exhausted = windows.find((window) => window.status === "exhausted");
  const stable = windows.find((window) => window.status === "stable");
  const highlight = risk || exhausted || stable || windows[0];
  const status = forecast.status === "excluded" ? "excluded" : highlight?.status || "insufficient";
  const explanation = forecastReason[forecast.reason] || (!risk && !exhausted && !stable ? forecastReason[highlight?.reason] : "");
  return `<section class="account-forecast" aria-label="${t("当前账户的预测")}">
    <div class="section-heading">
      <h3><span class="icon-area">${icon("chart")}</span>${t("额度可用性预测")}</h3>
      ${forecastDetailButton(account)}
    </div>
    <div class="cluster">${forecastBadge(status)}
      ${highlight ? `<span class="caption muted">${t(highlight.title)}</span>` : ""}
      ${risk ? `<span class="caption forecast-emphasis">${forecastTime(risk.estimatedExhaustedAt)}</span>` : ""}
    </div>
    ${explanation ? `<p class="caption muted">${t(explanation)}</p>` : ""}
  </section>`;
}

function forecastSpan(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  const minutes = Math.max(1, Math.round(seconds / 60));
  const hours = Math.floor(minutes / 60);
  const parts = [
    hours ? countText(hours, "小时", "h") : "",
    minutes % 60 ? countText(minutes % 60, "分钟", "min") : "",
  ].filter(Boolean);
  return parts.join(" ");
}

function forecastBasis(window) {
  const confidence = forecastConfidence[window.confidence];
  const span = forecastSpan(window.observedSpanSeconds);
  const hasRate = Number.isFinite(window.ratePercentPerHour) && window.ratePercentPerHour >= 0;
  const samples = Number.isFinite(window.sampleCount)
    && (window.sampleCount > 0 || window.sampleCount === 0 && window.reason === "insufficientHistory");
  if (!confidence && !span && !hasRate && !samples) return "";
  return `<div class="forecast-basis"><h4>${t("估算依据")}</h4><dl class="forecast-metrics">
    ${confidence ? forecastDatum("置信度", t(confidence)) : ""}
    ${samples ? forecastDatum("样本", text(countText(window.sampleCount, "次观测", "observations"))) : ""}
    ${span ? forecastDatum("观测跨度", text(span)) : ""}
    ${hasRate ? forecastDatum("观测速率", text(inEnglish()
      ? `${number(window.ratePercentPerHour)} percentage points/hour`
      : `${number(window.ratePercentPerHour)} 个百分点/小时`)) : ""}
  </dl></div>`;
}

function forecastWindowDetail(window) {
  const isEstimated = window.status === "risk" || window.status === "stable";
  const reason = forecastReason[window.reason];
  return `<article class="forecast-window panel" data-status="${text(window.status)}" data-window="${text(window.id)}" tabindex="-1">
    <div class="section-heading"><h3>${t(window.title)}</h3>${forecastBadge(window.status)}</div>
    <div class="forecast-window-readings">
      <div><h4>${t("实测")}</h4><dl class="forecast-metrics">
        ${forecastDatum("实测剩余", text(forecastRemaining(window.remainingPercent)))}
        ${forecastDatum("观测时间", forecastTime(window.observedAt))}
        ${window.resetsAt ? forecastDatum("记录的重置时间", forecastTime(window.resetsAt)) : ""}
        ${window.source ? forecastDatum("来源", text(window.source)) : ""}
      </dl></div>
      ${isEstimated ? `<div class="forecast-estimate"><h4>${t("趋势估算")}</h4>
        ${window.status === "risk" ? `<dl class="forecast-metrics">${forecastDatum("预计用尽", forecastTime(window.estimatedExhaustedAt), true)}</dl>`
          : `<p class="forecast-stable">${t(forecastStatus.stable)}</p>`}
      </div>` : ""}
    </div>
    ${reason ? `<p class="caption muted forecast-reason">${t(reason)}</p>` : ""}
    ${forecastBasis(window)}
  </article>`;
}

action("quota-forecast", (trigger) => {
  const account = accounts().find((account) => account.id === trigger.dataset.value);
  if (!account) return;
  const forecast = accountForecast(account);
  if (!forecast) return;
  const windows = forecastWindows(forecast);
  const timeZone = state.settings?.timeZone;
  const reason = forecastReason[forecast.reason];
  openDialog(`${editorHeading("额度可用性预测")}<div class="dialog-body forecast-dialog-content">
    <div class="forecast-dialog-context"><strong>${text(account.name)}</strong>
      ${timeZone ? `<span class="caption muted">${t("显示时区")} · ${text(timeZone)}</span>` : ""}
    </div>
    ${reason || !windows.length ? `<div class="panel forecast-exclusion">
      ${forecastBadge(forecast.status)}<p class="muted">${t(reason || forecastReason.noReadings)}</p>
    </div>` : ""}
    ${windows.map(forecastWindowDetail).join("")}
    ${windows.some((window) => window.status === "risk" || window.status === "stable")
      ? `<p class="caption muted">${t("后续使用速率变化时，预计时间会随新观测更新。")}</p>` : ""}
  </div><footer class="dialog-foot">${button("关闭", "close-dialog")}</footer>`, "forecast-dialog");
  if (trigger.dataset.window) {
    const selected = [...dialog.querySelectorAll(".forecast-window")].find((item) => item.dataset.window === trigger.dataset.window);
    selected?.scrollIntoView({ block: "nearest" });
    selected?.focus({ preventScroll: true });
  }
});
