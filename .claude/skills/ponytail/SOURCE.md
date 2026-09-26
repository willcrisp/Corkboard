# Source

Vendored from https://github.com/DietrichGebert/ponytail (MIT, see `LICENSE`),
commit `e3ba2aa6f1e6f0bc4d69eb09c9f0d0a93af56156` (plugin v4.10.0).

Only the six `skills/ponytail*` folders are copied, unmodified. The plugin's Node
lifecycle hooks (auto-activation, mode tracking) are not installed, so the skill
loads when a task matches its description or when you type `/ponytail`.

To update, copy `skills/ponytail*` from a newer checkout over `.claude/skills/`.
