// What the blocked page says (design 05: A in a session, C outside one,
// D and D2 for a strict or normal session without the app). Pure, so node can test it;
// blocked.js renders it.

var FocusBlockedView = (() => {
  const DAY_NAMES = { mon: "Mon", tue: "Tue", wed: "Wed", thu: "Thu", fri: "Fri", sat: "Sat", sun: "Sun" };
  const ORDER = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

  // "24:08", "1:00:05", as MenuBarStatus.format in the app.
  function countdown(seconds) {
    const total = Math.max(0, Math.floor(seconds));
    const h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
    const pad = (n) => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }

  // "25 min", rounded up, for Reduce Motion: it changes once a minute, as
  // SessionText.minutesLeft in the app.
  function minutes(seconds) {
    return `${Math.ceil(Math.max(0, seconds) / 60)} min`;
  }

  // "in 45 min", "in 7 h 33 min", "in 1 d 2 h".
  function relative(seconds) {
    const minutes = Math.max(0, Math.floor(seconds / 60));
    const d = Math.floor(minutes / 1440), h = Math.floor(minutes / 60) % 24, m = minutes % 60;
    if (d > 0) return `in ${d} d ${h} h`;
    if (h > 0) return `in ${h} h ${m} min`;
    return `in ${m} min`;
  }

  // "Mon–Fri", "Sat, Sun", "Every day", as RuleText.summary in the app.
  function days(list) {
    if (list.length >= 7) return "Every day";
    const runs = [];
    ORDER.forEach((day, i) => {
      if (!list.includes(day)) return;
      const run = runs[runs.length - 1];
      if (run && run[run.length - 1] === i - 1) run.push(i); else runs.push([i]);
    });
    return runs.flatMap((run) => run.length >= 3
      ? [`${DAY_NAMES[ORDER[run[0]]]}–${DAY_NAMES[ORDER[run[run.length - 1]]]}`]
      : run.map((i) => DAY_NAMES[ORDER[i]])).join(", ");
  }

  // "today at 18:00", "tomorrow at 08:00", "Mon at 08:00", in the Mac's zone.
  function clock(instant, timeZone) {
    return new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(instant));
  }

  function when(instant, now, timeZone) {
    const date = (t) => new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(t));
    const time = clock(instant, timeZone);
    if (date(instant) === date(now)) return `today at ${time}`;
    if (date(instant) === date(now + 86400000)) return `tomorrow at ${time}`;
    const weekday = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short" }).format(new Date(instant));
    return `${weekday} at ${time}`;
  }

  const reasonText = {
    session: (d) => `${d} is blocked during focus sessions`,
    schedule: (d) => `${d} is blocked by a schedule`,
    always: (d) => `${d} is blocked at all times`,
  };

  function hostOf(url) {
    try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return url; }
  }

  function model({ delivery, url, now, appRunning, timeZone, reduceMotion = false }) {
    const left = (seconds) => reduceMotion ? minutes(seconds) : countdown(seconds);
    const policy = delivery?.policy ?? null;
    const decision = FocusPolicy.decide(policy, url, now);
    const offline = appRunning === false;
    const openApp = { label: offline ? "Open FocusPilot" : "Return to task", action: "open-app" };

    if (decision.excepted) {
      const host = hostOf(url);
      const { scope, expiresAt } = decision.excepted;
      const what = scope.kind === "site" ? `All of ${scope.domain}` : "This page";
      return {
        kind: "excepted", domain: decision.domain,
        status: { tone: "green", text: `Timed exception · ${left((expiresAt - now) / 1000)} left` },
        title: `${host} is allowed for now`,
        subtitle: `${what} is allowed until ${clock(expiresAt, timeZone)}, then it is blocked again.`,
        primary: { label: `Go back to ${host}`, action: "go-back" }, backURL: FocusPolicy.returnURL(policy, url),
        exceptionLink: false, footer: ["", "FocusPilot"],
      };
    }

    if (!decision.blocked) {
      const host = hostOf(url);
      const backURL = FocusPolicy.returnURL(policy, url);
      return {
        kind: "unblocked", status: { tone: "gray", text: "Not blocked" }, title: `${host} isn't blocked now`,
        subtitle: "The rule that blocked it no longer applies.",
        primary: { label: backURL ? `Go back to ${host}` : "Open a new tab", action: "go-back" }, backURL,
        exceptionLink: false, footer: ["", "FocusPilot"],
      };
    }

    const domain = decision.domain;
    const session = policy?.session;
    const offlineSession = offline && decision.reason === "session";
    if (offlineSession && session.mode === "strict") {
      return {
        kind: "strict-offline", domain, status: { tone: "orange", text: "FocusPilot isn't running" },
        title: "Still blocked · strict session",
        subtitle: `Your last policy keeps ${domain} blocked until FocusPilot is running again.`,
        primary: { label: "Open FocusPilot", action: "open-app" },
        hint: "Applications › FocusPilot, or Spotlight. Exceptions can only be requested while it runs.",
        exceptionLink: false,
        footer: ["Your last rules are saved in Chrome · no planned end while strict", "FocusPilot"],
      };
    }
    if (offlineSession) {
      const end = clock(Date.parse(session.end), timeZone);
      return {
        kind: "normal-offline", domain, status: { tone: "orange", text: "FocusPilot isn't running" },
        title: `Still blocked until ${end}`,
        subtitle: `This normal session keeps ${domain} blocked until its planned end, then the rule lifts even if FocusPilot stays closed.`,
        primary: { label: "Open FocusPilot", action: "open-app" },
        hint: "Open it from Applications or Spotlight to pause, complete, or request an exception.",
        exceptionLink: false,
        footer: [`Your last rules are saved in Chrome · the session ends at ${end}`, "FocusPilot"],
      };
    }
    const offlineHint = offline ? "FocusPilot isn't running. Open it from Applications or Spotlight to request an exception." : null;

    if (FocusPolicy.sessionApplies(session, now) && delivery.focus) {
      // A paused strict session's countdown stands still until it resumes.
      const paused = session.pausedSince ? Date.parse(session.pausedSince) : null;
      const remaining = Date.parse(session.end) - (paused ?? now);
      const status = remaining <= 0 ? "Strict session · past its planned end"
        : paused ? `Focus session paused · ${left(remaining / 1000)} left` : `Focus session · ${left(remaining / 1000)} left`;
      return {
        kind: "session", domain, status: { tone: "accent", text: status }, eyebrow: "You're working on",
        title: delivery.focus.title, subtitle: delivery.focus.nextAction ?? delivery.focus.projectTitle ?? null,
        primary: openApp, hint: offlineHint, exceptionLink: !offline,
        footer: [reasonText[decision.reason](domain), "FocusPilot · Chrome"],
      };
    }

    let subtitle = null, detail = "Always-on rule · no end time";
    if (decision.reason === "schedule") {
      const s = decision.schedule;
      subtitle = `${days(s.days)} ${s.start}–${s.end} · ${s.timeZone}`;
      const end = FocusPolicy.scheduleNextChange(s, now);
      detail = end ? `Schedule ends ${when(end, now, timeZone)} · ${relative((end - now) / 1000)}` : null;
    } else if (decision.reason === "session") {
      detail = "Blocked during focus sessions";
    }
    return {
      kind: "rule", domain, status: { tone: "gray", text: "No session running" },
      title: reasonText[decision.reason](domain), subtitle, detail,
      primary: { label: "Open FocusPilot", action: "open-app" }, hint: offlineHint, exceptionLink: !offline,
      footer: ["", "FocusPilot"],
    };
  }

  // StrictEarlyEnd.wait in the app; the real wait comes back as `availableAt`.
  const STRICT_WAIT_TEXT = "1 minute";
  const DURATIONS = [300, 600, 1200];

  // "youtube.com/watch?v=3kqW9M…": the page as the scope choice shows it.
  function shortPage(url) {
    let text;
    try {
      const u = new URL(url);
      text = u.hostname.replace(/^www\./, "") + u.pathname + u.search;
    } catch { text = url; }
    return text.length > 40 ? text.slice(0, 39) + "…" : text;
  }

  // The timed exception form (design 05B). `state` is the page's: the
  // chosen duration and scope, the reason, and the phase of the request:
  // editing, confirming (strict: asked to confirm), waiting (strict: the
  // wait until `availableAt`), or sending.
  function exceptionForm({ delivery, url, now, state }) {
    const policy = delivery?.policy ?? null;
    const decision = FocusPolicy.decide(policy, url, now);
    const domain = decision.domain ?? hostOf(url);
    const strict = policy?.session?.mode === "strict" && FocusPolicy.sessionApplies(policy.session, now);
    const minutes = (seconds) => `${seconds / 60} min`;
    const waiting = state.phase === "waiting";
    const remaining = waiting ? Math.max(0, state.availableAt - now) : 0;

    let allow;
    if (state.phase === "sending") allow = { label: "Allowing…", disabled: true };
    else if (state.phase === "confirming") allow = { label: "Start the wait", disabled: false };
    else if (waiting) allow = remaining > 0 ? { label: `Allow in ${countdown(remaining / 1000)}`, disabled: true } : { label: "Allow now", disabled: false };
    else allow = { label: `Allow for ${minutes(state.duration)}`, disabled: strict && !state.reason.trim() };

    let waitNote = null;
    if (state.phase === "confirming") waitNote = `A strict session waits ${STRICT_WAIT_TEXT} before allowing it.`;
    else if (waiting && remaining > 0) waitNote = `Strict session · Allow becomes available in ${countdown(remaining / 1000)}`;

    const reason = state.reason.trim();
    return {
      title: "Timed exception", strict,
      note: "Applies in every Chrome profile. Ends at the time shown, not at the session end.",
      durations: DURATIONS.map((seconds) => ({ seconds, label: minutes(seconds), selected: seconds === state.duration })),
      scopes: [
        { id: "page", label: "This page only", detail: shortPage(url), selected: state.scope === "page" },
        { id: "site", label: `All of ${domain}`, detail: "Every page on the site", selected: state.scope === "site" },
      ],
      reason: strict ? { placeholder: `Why this ${state.scope === "site" ? "site" : "page"} is needed for the task` } : null,
      locked: waiting || state.phase === "sending",
      waitNote, allow, error: state.error ?? null,
      request: {
        scope: state.scope === "site" ? { kind: "site", domain } : { kind: "page", url },
        durationSeconds: state.duration, reason: strict && reason ? reason : null,
        confirmed: state.phase === "confirming",
      },
    };
  }

  // Where an arrow, Home or End key moves the choice in a radio group of
  // `count`, wrapping around; null for any other key.
  function nextChoice(index, count, key) {
    switch (key) {
      case "ArrowRight": case "ArrowDown": return (index + 1) % count;
      case "ArrowLeft": case "ArrowUp": return (index - 1 + count) % count;
      case "Home": return 0;
      case "End": return count - 1;
      default: return null;
    }
  }

  return { model, exceptionForm, countdown, relative, days, when, nextChoice };
})();

if (typeof module === "object") module.exports = FocusBlockedView;
