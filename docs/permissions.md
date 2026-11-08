[← Back to the README](../README.md)

# Permissions

| Permission | Why |
|---|---|
| Microphone, Speech Recognition | push-to-talk questions |
| Screen Recording | screenshots sent with each question |
| Accessibility | only for working in apps (pressing controls, clicking, typing) once you let Cursor Pilot work on your Mac |
| Full Disk Access | reading Messages, and files anywhere without macOS asking per folder |
| Contacts | names instead of numbers in messages |
| Automation (Messages, Finder, System Events) | sending texts, and the few scripts the agent may run |
| Local Network | reaching devices and servers on your network from a task |

Everything is asked for once, up front: Settings › Permissions › **Set Up
Everything** (and the onboarding's Allow Everything) shows the dialogs that
can appear in place one after the other, then opens System Settings at each
switch still off. While it works Cursor Pilot never asks: it only checks,
and when something is missing it says what to set up instead of putting a
dialog in front of you. The agent is told not to script other apps, which
would make macOS ask. macOS doesn't let apps grant themselves permissions,
so the switches stay yours. `-CPPermissions out.json` reports what's
allowed without asking.

If a permission is switched on but Cursor Pilot still can't use it, the
entry was made by an older build signed another way (for example ad hoc,
before you ran `dev-signing-identity.sh`). Reset it and allow it again:

```bash
tccutil reset Accessibility com.louistuis.cursorpilot   # or ScreenCapture
```

Talking needs no Accessibility permission: the shortcut is a Carbon hot key
and the buddy only reads the mouse position.
