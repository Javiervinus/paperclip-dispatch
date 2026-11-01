# Changelog

What changed for the person using Paperclip Dispatch, in plain language. Changes nobody can notice are
left out on purpose. Paperclip itself has its own versions and its own notes; they are not listed here.

Paperclip Dispatch follows [semantic versioning](https://semver.org/). Dates are ISO 8601. The same notes
are in Spanish in [CHANGELOG.es.md](CHANGELOG.es.md): keep both in step.

The app shows the newest section in its updates panel, so each item starts with a bold sentence that
stands on its own and adds one or two more at most. Past the fifth item, the panel links here.

## Unreleased

### Added

- **Answer Paperclip’s multi-step cards from Telegram.** Forms with several questions, suggested tasks,
  checklists, item-by-item reviews and decisions with fields come as one message that updates as you go.
  Nothing reaches Paperclip until the final button, so the agent wakes up only once.
- **You hear about the tasks an agent assigns you.** A Mac notification and a Telegram message say which
  task, who assigned it, its project and how it starts; reply to the message to comment on the task. When
  it’s closed or reassigned, the message says so. The ones you assign yourself don’t notify, and Settings →
  Notifications can turn it off.
- **Answer more decisions from Telegram.** Join requests, reviews waiting for you, board approvals, failed
  runs, agent errors and budget stops now come with their own buttons, and “Wake up” only shows when the
  agent isn’t already on its way: if it has a run queued or in progress, the message and the Mac
  notification say so instead.

### Fixed

- **Decisions come to Telegram with their buttons, and a text question has a single button to write.**
  Until now, decisions said “Answer it in Paperclip” even when they could be answered from Telegram.

## 0.1.0 — 2026-11-01

The first release. Everything below is new, so this entry describes the app rather than listing changes.

### Added

- **Paperclip in its own Mac window.** A native app instead of a browser tab: Paperclip fills the whole
  window, with no title bar, in its black and white and with Liquid Glass and the Mac's own menus,
  shortcuts and window behavior.
- **Decisions without looking.** A Mac notification when an agent asks a question, needs an approval or
  fails, or a budget alert goes off, and on the Dock icon the same number as Decisions in Paperclip's
  sidebar.
- **Answer from Telegram.** Link a Telegram bot to get each decision on your phone and approve, reject,
  answer or ask "explain it to me" from there.
- **Unstick a task in one click.** When a task is stuck with an agent (e.g. a reviewer Paperclip never
  woke up), the Mac notification and the Telegram message offer a button to wake that agent up and tell
  you whether Paperclip woke it or skipped it.
- **A welcome that gets you set up.** On first launch the app introduces itself, finds Paperclip on this
  Mac (starting it, helping install it, or taking another address) and shows what notifications look like
  before asking for them. If they end up off, it reminds you, without getting in the way.
- **Updates for both, in one place.** The button at the top right shows the version of Paperclip and of
  this app. Paperclip updates only when you say so; the app downloads its own updates and installs them
  when you restart it or quit.
- **In English or Spanish.** The app follows your Mac's language, and so do the Telegram bot and its
  "explain it to me" answers.
