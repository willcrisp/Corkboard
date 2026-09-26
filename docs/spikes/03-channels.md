# 03: Password-protected channel reach and the channel limit

**Status:** not run yet. The tooling is ready in `spikes/CorkSpike2/`.

## Question

- Does a password-protected temporary channel (`JoinTemporaryChannel(name, password)`) reach members on the same realm, on a connected realm, and on an unconnected realm (same region)? §5.1 assumes at least same and connected realms.
- Does a wrong password keep a character out, and what notice does it give?
- How many custom channels can one character join? §5.1 caps Corkboard at 3 channel-backed boards and assumes that leaves room for the player's own channels.
- Once removed from every chat frame, does the channel ever show text or join/leave notices in chat? (Phase 2 acceptance: "the hidden channel never shows in any chat frame".) Which removal function exists: `ChatFrame_RemoveChannel`, `ChatFrameUtil.RemoveChannel` or a frame method?

## How it was tested

- Client build, realm(s), date:
- Characters and realms used (same / connected / other):
- Steps:
  1. On one character: `/cspike2 limit`, then `/cspike2 report`.
  2. On every character at once: `/cspike2 reach CorkReachTest <password>`. Leave it running for a minute, then `/cspike2 reach off` and `/cspike2 report`.
  3. On one extra character: `/cspike2 reach CorkReachTest wrongpassword`.
  4. Watch every chat tab during step 2 for anything mentioning the channel.

## Result

_Paste the "Spike 03" part of each character's report here, and note anything you saw in chat._

| Measure | Value |
|---|---|
| Custom channels per character | |
| Same realm | |
| Connected realm | |
| Other realm, same region | |
| Wrong password | |
| Removal function that worked | |
| Anything visible in chat | |

## Design impact

_For example: the channel cap in §5.1, whether cross-realm members need WHISPER or BNet instead, and how the addon hides the channel (§5.1, Phase 2)._
