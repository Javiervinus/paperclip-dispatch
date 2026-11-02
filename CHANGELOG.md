# Changelog

What changed for the person using Paperclip Dispatch, in plain language. Changes nobody can notice are
left out on purpose. Paperclip itself has its own versions and its own notes; they are not listed here.

Paperclip Dispatch follows [semantic versioning](https://semver.org/). Dates are ISO 8601. The same notes
are in Spanish in [CHANGELOG.es.md](CHANGELOG.es.md): keep both in step.

The app shows the newest section in its updates panel, so each item starts with a bold sentence that
stands on its own and adds one or two more at most. Past the fifth item, the panel links here.

## Unreleased

### Added

- **Update Paperclip’s plugins from the updates panel.** Plugins installed from npm show their new version
  and an Update button, and Paperclip swaps the plugin without stopping your agents. Plugins installed from
  a folder are listed too, but they update in that folder.

## 0.3.0 — 2026-11-02

### Added

- **Paperclip plugins that write with Chrome’s built-in AI work in the app, with Apple Intelligence.** The
  ones that use it, like Oficina global’s conversations, get this Mac’s on-device model, with nothing to
  download. It needs Apple Intelligence turned on in System Settings.
- **Plugins can notify you on the Mac, if you let them.** A plugin that asks to show notifications, like
  Oficina global’s system notice, now gets Mac notifications instead of a “Blocked”; a click brings you
  back to it. Settings → Notifications can turn them off.

### Fixed

- **New versions reach you within an hour.** The app now looks for them every hour instead of every six,
  so you no longer need “Check Now” to get one the day it comes out.
- **A plugin’s 3D view follows the mouse.** As in Chrome, a click captures the pointer to look around and
  Esc lets it go; before, you had to drag.
- **PDFs have a way back, and their download button works.** A PDF or any other file opened from Paperclip
  shows a back button next to the window buttons, and the viewer’s download button asks where to save it.
- **The image viewer no longer runs into the window buttons.** The file name sits to their right, like a
  window title.

## 0.2.0 — 2026-11-01

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
- **Agents that Paperclip forgets to wake up get woken up.** When Paperclip 2026.1023.0 hands a task to an
  agent (for review, back to whoever did it, or to someone new) and loses its wake-up, the app wakes it once,
  quietly, two minutes later; if that fails, or if Paperclip’s answer can’t be read, you get the stuck-task
  notification instead. It’s on by default and can be turned off in Settings → Paperclip.
- **“Open preview” on the cards whose task has something served to look at.** When an agent registers a
  preview of its work in the task (a page, a web app), the Mac notification brings an action that opens it,
  and the Telegram message of its decision or assigned task, a link next to the description, in every step of
  a multi-step card. A `localhost` address only opens from the Mac.
- **You hear when an agent hits its daily run limit.** Paperclip then skips everything that would wake it,
  without saying so: a Mac notification and a Telegram message say which agent, its limit and at what time the
  count resets, with a button to its page to raise it. Once a day per agent, and Settings → Notifications can
  turn it off.
- **If Paperclip changes what it answers, the new features step aside instead of guessing.** A card, button
  or notice the app can't read properly goes back to “Open in Paperclip”, and if Paperclip rejects an answer,
  the message says it couldn't be done and offers to open it there.

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
