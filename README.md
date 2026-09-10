<p align="center">
  <a href="https://hermes.xpetalab.dev">
    <img
      src="assets/branding/hermes_
  </a>
</p>

<p align="center">
  A private, Android-first console for the self-hosted Hermes Agent you control.
</p>

<p align="center">
  <a href="https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole">
    <img height="64" alt="Get Hermes Console on Google Play" src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" />
  </a>
  <a href="https://hermes.xpetalab.dev/obtainium/">
    <img height="64" alt="Add Hermes Console to Obtainium" src="https://raw.githubusercontent.com/ImranR98/Obtainium/main/assets/graphics/badge_obtainium.png" />
  </a>
</p>

<p align="center">
  <a href="https://hermes.xpetalab.dev">
    <img alt="Website" src="https://img.shields.io/badge/Website-hermes.xpetalab.dev-F59E0B?style=flat-square&logo=googlechrome&logoColor=white" />
  </a>
  LICENSE
    <img alt="GPL-3.0-only" src="https://img.shields.io/badge/license-GPL--3.0--only-7C3AED?style=flat-square" />
  </a>
  <img alt="Android 7+" src="https://img.shields.io/badge/Android-7.0%2B-3DDC84?style=flat-square&logo=android&logoColor=white" />
</p>

<p align="center">
  docs/README_ES.mdEspañol</a> ·
  docs/INSTALLATION.mdInstallation</a> ·
  docs/CONFIGURATION.mdServer setup</a> ·
  docs/PRIVACY_POLICY.mdPrivacy</a> ·
  <a href="SECURITY.md">Security</a>
</p>

Hermes Console is an independent Flutter client for
https://github.com/NousResearch/hermes-agent. It brings chat,
Bots, operations, approvals, and Voice to Android without placing an XPeta Lab
account or analytics service between your phone and your server.

> Hermes Console is a client, not an AI provider. You need a compatible Hermes
> Agent instance and any model-provider access required by that instance.

> [!IMPORTANT]
> ## Fork notice
>
> This repository is an independent fork and continuation of
> https://github.com/rusty4444/hermes-android.
> The maintainer of this fork is **not the owner or original author** of the
> upstream project and does not claim ownership of its original work.
>
> Full credit for the original foundation belongs to the upstream author and
> contributors. This fork builds upon that work with additional features, bug
> fixes, maintenance updates, interface improvements, Android-specific polish,
> operational tooling, and quality-of-life enhancements.
>
> This fork is independently maintained and is not an official release of the
> original repository.

## What you can do

| Surface | Native Android experience |
|---|---|
| Conversations | Streaming Markdown and code, attachments, generated images, session history, and model selection. |
| Bots | Profiles, Blobatar identities, mentions, rooms, tasks, and activity kept separate from normal conversations. |
| Operations | Runs and approvals, Cron, Kanban, skills, memory, models, artifacts, and capability-aware admin tools. |
| Voice | Dictation plus a dedicated conversation mode with phone or Hermes-server speech routes and explicit fallbacks. |
| Android | App Lock, read-only instances, notifications, widgets, share sheet, QR pairing, and connection diagnostics. |
| Privacy | No XPeta Lab telemetry, no advertising SDK, and credentials protected with Android Keystore. |

The app follows Hermes Desktop and Hermes Agent as the protocol contract. A
feature is shown only when the connected server exposes the capability it
needs. Older servers degrade gracefully without inventing endpoints.

## See it in action

<table>
  <tr>
    <td align="center"><strong>Home</strong></td>
    <td align="center"><strong>Conversations</strong></td>
    <td align="center"><strong>Voice</strong></td>
    <td align="center"><strong>Tools</strong></td>
  </tr>
  <tr>
    <td>docs/screenshots/1.2.4-912/home.png</td>
    <td>docs/screenshots/1.2.4-912/chat.png</td>
    <td>docs/screenshots/1.2.4-912/voice.png</td>
    <td>docs/screenshots/1.2.4-912/tools.png</td>
  </tr>
</table>

The gallery uses the approved public demo set with fictional data. Screens may
vary slightly by app version and by the capabilities exposed by your Hermes
server.

## Install

### Google Play

[Install the production package from Google Play](https://play.google.com/store/apps/details?id=dev.xpetalab.hermesconsole).

The package ID is `dev.xpetalab.hermesconsole`, and Play builds use Play App
Signing.

### Obtainium

After the first signed GitHub release is published, Obtainium can follow the
release feed directly:

1. Install https://github.com/ImranR98/Obtainium.
2. Use **[Add Hermes Console to Obtainium](https://hermes.xpetalab.dev/obtainium/)**.
   The button opens Obtainium's Add App screen with the repository already
   filled in.
3. Confirm that the detected source is **GitHub Releases** and review the APK
   signature before installing.

If Android blocks the handoff, open **Add App** in Obtainium and paste the
following repository URL manually:

```text
https://github.com/blofstedt/hermes-console
