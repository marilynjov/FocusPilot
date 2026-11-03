import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
globalThis.FocusPolicy = require("../../Extensions/Chrome/policy.js");
const FocusBlockedView = require("../../Extensions/Chrome/blocked-view.js");

const at = (iso) => Date.parse(iso);
const weekdays = { days: ["mon", "tue", "wed", "thu", "fri"], start: "08:00", end: "18:00", timeZone: "America/Bogota" };
// Wednesday 2026-10-14, 10:26:52 in Bogotá.
const now = at("2026-10-14T15:26:52Z");

function delivery({ session = null, focus = null } = {}) {
  return {
    policy: {
      schemaVersion: 1, revision: 41, checksum: "c", effectiveAt: "2026-10-14T15:00:00Z",
      always: { domains: ["facebook.com"], apps: [] },
      scheduled: [{ schedule: weekdays, targets: { domains: ["instagram.com"], apps: [] } }],
      session, allowed: { domains: [], apps: [], tools: [] },
    },
    focus,
  };
}

const session = (mode = "normal") => ({ sessionID: "s", mode, end: "2026-10-14T15:51:00Z", targets: { domains: ["youtube.com"], apps: [] } });
const focus = { title: "Explain baseline results", nextAction: "Open Overleaf §4.2 and write the baseline paragraph using Table 3.", projectTitle: "NLP report" };
const view = (d, url, extra = {}) => FocusBlockedView.model({ delivery: d, url, now, appRunning: true, timeZone: "America/Bogota", ...extra });

test("during a session the page shows the task and the way back", () => {
  const m = view(delivery({ session: session(), focus }), "https://www.youtube.com/watch?v=3kqW9M");

  assert.equal(m.kind, "session");
  assert.equal(m.status.text, "Focus session · 24:08 left");
  assert.equal(m.eyebrow, "You're working on");
  assert.equal(m.title, "Explain baseline results");
  assert.equal(m.subtitle, focus.nextAction);
  assert.deepEqual(m.primary, { label: "Return to task", action: "open-app" });
  assert.equal(m.exceptionLink, true);
  assert.deepEqual(m.footer, ["youtube.com is blocked during focus sessions", "FocusPilot · Chrome"]);
});

test("a site blocked by a schedule during a session still shows the task", () => {
  const m = view(delivery({ session: session(), focus }), "https://instagram.com/");

  assert.equal(m.kind, "session");
  assert.equal(m.footer[0], "instagram.com is blocked by a schedule");
});

test("outside a session a schedule says when it ends", () => {
  const m = view(delivery(), "https://instagram.com/");

  assert.equal(m.kind, "rule");
  assert.equal(m.status.text, "No session running");
  assert.equal(m.title, "instagram.com is blocked by a schedule");
  assert.equal(m.subtitle, "Mon–Fri 08:00–18:00 · America/Bogota");
  assert.equal(m.detail, "Schedule ends today at 18:00 · in 7 h 33 min");
  assert.deepEqual(m.primary, { label: "Open FocusPilot", action: "open-app" });
});

test("always-on rules have no end", () => {
  const m = view(delivery(), "https://facebook.com/");

  assert.equal(m.title, "facebook.com is blocked at all times");
  assert.equal(m.detail, "Always-on rule · no end time");
});

test("a strict session past its end without the app says how to reopen it", () => {
  const m = view(delivery({ session: session("strict"), focus }), "https://youtube.com/", { now: at("2026-10-14T16:30:00Z"), appRunning: false });

  assert.equal(m.kind, "strict-offline");
  assert.equal(m.status.text, "FocusPilot isn't running");
  assert.equal(m.title, "Still blocked · strict session");
  assert.equal(m.subtitle, "Your last policy keeps youtube.com blocked until FocusPilot is running again.");
  assert.equal(m.hint, "Applications › FocusPilot, or Spotlight. Exceptions can only be requested while it runs.");
  assert.equal(m.exceptionLink, false);
  assert.deepEqual(m.footer, ["Your last rules are saved in Chrome · no planned end while strict", "FocusPilot"]);
});

// Design 05 D applies to the whole strict session, not only past its end.
test("a strict session before its end without the app is variant D", () => {
  const m = view(delivery({ session: session("strict"), focus }), "https://youtube.com/", { appRunning: false });

  assert.equal(m.kind, "strict-offline");
  assert.equal(m.title, "Still blocked · strict session");
});

test("a normal session without the app says when the rule lifts (05 D2)", () => {
  const m = view(delivery({ session: session(), focus }), "https://youtube.com/", { appRunning: false });

  assert.equal(m.kind, "normal-offline");
  assert.deepEqual(m.status, { tone: "orange", text: "FocusPilot isn't running" });
  assert.equal(m.title, "Still blocked until 10:51");
  assert.equal(m.subtitle, "This normal session keeps youtube.com blocked until its planned end, then the rule lifts even if FocusPilot stays closed.");
  assert.deepEqual(m.primary, { label: "Open FocusPilot", action: "open-app" });
  assert.equal(m.hint, "Open it from Applications or Spotlight to pause, complete, or request an exception.");
  assert.equal(m.exceptionLink, false);
  assert.deepEqual(m.footer, ["Your last rules are saved in Chrome · the session ends at 10:51", "FocusPilot"]);
});

// The offline session variants speak about the session, so a site blocked
// only by another rule keeps naming that rule.
test("without the app, a site blocked only by an always-on rule still says so", () => {
  const strictPast = { now: at("2026-10-14T16:30:00Z"), appRunning: false };
  for (const extra of [strictPast, { appRunning: false }]) {
    const m = view(delivery({ session: session("strict"), focus }), "https://facebook.com/", extra);

    assert.equal(m.kind, "session");
    assert.equal(m.footer[0], "facebook.com is blocked at all times");
    assert.deepEqual(m.primary, { label: "Open FocusPilot", action: "open-app" });
    assert.equal(m.exceptionLink, false);
    assert.equal(m.hint, "FocusPilot isn't running. Open it from Applications or Spotlight to request an exception.");
  }
});

test("a page that is no longer blocked offers to go back", () => {
  const m = view(delivery({ session: session(), focus }), "https://youtube.com/watch?v=1", { now: at("2026-10-14T16:00:00Z") });

  assert.equal(m.kind, "unblocked");
  assert.equal(m.title, "youtube.com isn't blocked now");
  assert.deepEqual(m.primary, { label: "Go back to youtube.com", action: "go-back" });
  assert.equal(m.backURL, "https://youtube.com/watch?v=1");
});

// Anyone can link to blocked.html, so ?from= must not send the owner to an
// arbitrary site: only back to a domain the rules name, or a new tab.
test("going back only returns to a site the rules name", () => {
  const later = { now: at("2026-10-14T16:00:00Z") };
  const d = delivery({ session: session(), focus });
  const back = (url) => view(d, url, later).backURL;

  assert.equal(back("https://m.youtube.com/watch?v=1"), "https://m.youtube.com/watch?v=1");
  const evening = { now: at("2026-10-15T01:00:00Z") }; // Wed 20:00 in Bogotá, after the schedule
  assert.equal(view(d, "http://instagram.com/", evening).backURL, "http://instagram.com/");
  assert.equal(back("https://evil.example/"), null);
  assert.equal(back("https://notyoutube.com/"), null);
  assert.equal(back("https://youtube.com.evil.example/"), null);
  assert.equal(back("javascript:alert(1)"), null);
  assert.equal(back("data:text/html,hi"), null);
  assert.equal(back("chrome://settings/"), null);
  assert.equal(back("not a url"), null);
  assert.equal(view(null, "https://youtube.com/", later).backURL, null, "no policy names nothing");
  assert.deepEqual(view(d, "https://evil.example/", later).primary, { label: "Open a new tab", action: "go-back" });
});

test("durations read like the rest of FocusPilot", () => {
  assert.equal(FocusBlockedView.countdown(24 * 60 + 8), "24:08");
  assert.equal(FocusBlockedView.countdown(3600 + 5), "1:00:05");
  assert.equal(FocusBlockedView.relative(45 * 60), "in 45 min");
  assert.equal(FocusBlockedView.relative(26 * 3600 + 60), "in 1 d 2 h");
});

// ---- Timed exceptions (design 05B, #14) ----

const videoURL = "https://www.youtube.com/watch?v=3kqW9MabcdEFG&list=PL1";
const form = (mode, state = {}, extra = {}) => FocusBlockedView.exceptionForm({
  delivery: delivery({ session: session(mode), focus }), url: videoURL, now, timeZone: "America/Bogota",
  state: { duration: 600, scope: "page", reason: "", phase: "editing", ...state }, ...extra,
});

test("the exception form offers 5, 10 or 20 minutes for this page or the whole site", () => {
  const f = form("normal");

  assert.equal(f.title, "Timed exception");
  assert.equal(f.note, "Applies in every Chrome profile. Ends at the time shown, not at the session end.");
  assert.deepEqual(f.durations, [{ seconds: 300, label: "5 min", selected: false }, { seconds: 600, label: "10 min", selected: true }, { seconds: 1200, label: "20 min", selected: false }]);
  assert.deepEqual(f.scopes.map((s) => [s.id, s.label, s.selected]), [["page", "This page only", true], ["site", "All of youtube.com", false]]);
  assert.equal(f.scopes[0].detail, "youtube.com/watch?v=3kqW9MabcdEFG&list=…");
  assert.equal(f.scopes[1].detail, "Every page on the site");
  assert.equal(f.reason, null, "only strict sessions ask why");
  assert.deepEqual(f.allow, { label: "Allow for 10 min", disabled: false });
});

test("the request names the page as it was blocked, or the rule's site", () => {
  assert.deepEqual(form("normal").request, { scope: { kind: "page", url: videoURL }, durationSeconds: 600, reason: null, confirmed: false });
  assert.deepEqual(form("normal", { scope: "site", duration: 300 }).request.scope, { kind: "site", domain: "youtube.com" });
});

test("a strict session asks why, then confirms, then counts down a wait", () => {
  const editing = form("strict");
  assert.equal(editing.strict, true);
  assert.equal(form("normal").strict, false);
  assert.equal(editing.reason.placeholder, "Why this page is needed for the task");
  assert.equal(editing.allow.disabled, true, "no reason yet");
  assert.equal(form("strict", { scope: "site" }).reason.placeholder, "Why this site is needed for the task");

  const withReason = form("strict", { reason: "Lecture for §4.2" });
  assert.equal(withReason.allow.disabled, false);
  assert.equal(withReason.request.reason, "Lecture for §4.2");

  const confirming = form("strict", { reason: "Lecture", phase: "confirming" });
  assert.equal(confirming.waitNote, "A strict session waits 1 minute before allowing it.");
  assert.deepEqual(confirming.allow, { label: "Start the wait", disabled: false });
  assert.equal(confirming.request.confirmed, true);

  const waiting = form("strict", { reason: "Lecture", phase: "waiting", availableAt: now + 42000 });
  assert.equal(waiting.waitNote, "Strict session · Allow becomes available in 0:42");
  assert.deepEqual(waiting.allow, { label: "Allow in 0:42", disabled: true });
  assert.equal(waiting.locked, true, "duration, scope and reason stay as confirmed");

  const ready = form("strict", { reason: "Lecture", phase: "waiting", availableAt: now - 1 });
  assert.deepEqual(ready.allow, { label: "Allow now", disabled: false });
});

test("while a request is on its way the form waits for FocusPilot", () => {
  assert.deepEqual(form("normal", { phase: "sending" }).allow, { label: "Allowing…", disabled: true });
  assert.equal(form("normal", { error: "FocusPilot isn't running." }).error, "FocusPilot isn't running.");
});

test("an excepted page says until when it is allowed and offers the way back", () => {
  const d = delivery({ session: session(), focus });
  d.policy.exceptions = [{ scope: { kind: "page", url: "https://youtube.com/watch?v=3kqW9MabcdEFG" }, expiresAt: "2026-10-14T15:36:52Z" }];
  const m = view(d, videoURL);

  assert.equal(m.kind, "excepted");
  assert.deepEqual(m.status, { tone: "green", text: "Timed exception · 10:00 left" });
  assert.equal(m.title, "youtube.com is allowed for now");
  assert.equal(m.subtitle, "This page is allowed until 10:36, then it is blocked again.");
  assert.deepEqual(m.primary, { label: "Go back to youtube.com", action: "go-back" });
  assert.equal(m.backURL, videoURL);
  assert.equal(m.exceptionLink, false);

  d.policy.exceptions = [{ scope: { kind: "site", domain: "youtube.com" }, expiresAt: "2026-10-14T15:36:52Z" }];
  assert.equal(view(d, videoURL).subtitle, "All of youtube.com is allowed until 10:36, then it is blocked again.");
});

// #23: with Reduce Motion the timers change once a minute, rounded up, as
// the focus panel does (design 04); the strict wait keeps its seconds.
test("with Reduce Motion the countdowns read in whole minutes", () => {
  const d = delivery({ session: session(), focus });
  assert.equal(view(d, "https://youtube.com/", { reduceMotion: true }).status.text, "Focus session · 25 min left");
  d.policy.exceptions = [{ scope: { kind: "site", domain: "youtube.com" }, expiresAt: "2026-10-14T15:36:22Z" }];
  assert.equal(view(d, "https://youtube.com/", { reduceMotion: true }).status.text, "Timed exception · 10 min left");
  assert.equal(view(d, "https://youtube.com/").status.text, "Timed exception · 9:30 left", "seconds without it");
});

// #23: the duration and scope choices are radio groups, so arrow keys move
// the choice and Home/End jump to the ends, wrapping around.
test("arrow keys move through a radio group", () => {
  const next = FocusBlockedView.nextChoice;
  assert.equal(next(0, 3, "ArrowRight"), 1);
  assert.equal(next(0, 3, "ArrowDown"), 1);
  assert.equal(next(2, 3, "ArrowRight"), 0);
  assert.equal(next(0, 3, "ArrowLeft"), 2);
  assert.equal(next(1, 3, "ArrowUp"), 0);
  assert.equal(next(1, 3, "Home"), 0);
  assert.equal(next(0, 3, "End"), 2);
  assert.equal(next(0, 3, "Tab"), null);
  assert.equal(next(0, 3, "a"), null);
});

// A paused strict session keeps blocking with its countdown standing still
// (owner decision, 2026-11-02).
test("a paused strict session shows the time left standing still", () => {
  const paused = { ...session("strict"), pausedSince: "2026-10-14T15:00:00Z" };
  const m = view(delivery({ session: paused, focus }), "https://youtube.com/");
  assert.equal(m.status.text, "Focus session paused · 51:00 left");
});
