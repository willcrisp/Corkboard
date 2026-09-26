# Phase 0 spikes

Each spike answers one question about the Forever client (docs/design.md §12, Phase 0). Write each answer as `NN-topic.md` with: the question, how it was tested (client build, realm, steps), the result, and any design change it forces. Re-check every answer after launch (2026-11-04).

| # | Question | File |
|---|---|---|
| 01 | Exact outgoing addon-message restriction API on 16001, when it's true, and the `SendAddonMessage` result codes | `01-send-restriction.md` |
| 02 | Per-prefix throttle: burst, sustained rate, and whether whisper, channel, guild and BNet share one budget | `02-throttle.md` |
| 03 | Password-protected custom channel reach (same realm, connected, cross-realm) and per-character channel limit | `03-channels.md` |
| 04 | Hyperlinks survive the LibDeflate addon-channel encode/decode round trip | `04-link-roundtrip.md` |
| 05 | `BNSendGameData` on Forever: payload size and throttle | `05-bnet.md` |
| 06 | SavedVariables fresh-launch bug status, and how the companion identifies the Forever install folder | `06-install-and-sv.md` |
