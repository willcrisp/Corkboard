# 01: Outgoing addon-message restriction and result codes

**Status:** not run yet. The tooling is ready in `spikes/CorkSpike/`.

## Question

- What is the client's outgoing addon-message restriction check called on 16001? §5.5 assumes `AreOutgoingAddonChatMessagesRestricted()`.
- When is it true: encounters, death, resurrection, anything else? How long does it stay true after each?
- What result codes can `SendAddonMessage` return, with names and values? Which one does a restricted send return, and does a restricted send return a code or raise an error?

## How it was tested

- Client build, realm, date:
- Addons loaded besides CorkSpike:
- Steps:
  1. `/cspike all`, or `/cspike probe` then `/cspike codes`.
  2. `/cspike canary on`, then pull a boss, wipe, die, release, resurrect, and get combat-resurrected.
  3. `/cspike canary off`, then `/cspike report`.

## Result

_Paste the "Spike 01" part of the report here, plus the canary lines from its Log section._

## Design impact

_For example: the real function name for §5.5, the result code the outbox should treat as "restricted", and how long the gate stays shut after death or an encounter._
