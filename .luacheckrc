-- luacheck config: run `luacheck .` from the repo root.
std = "lua51"
max_line_length = 120
exclude_files = { "addon/Corkboard/Libs/**" }

-- The specs run under busted.
files["addon/spec/**"] = { std = "+busted" }
