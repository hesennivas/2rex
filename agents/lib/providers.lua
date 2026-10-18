-- agent adapters. add a table here to support another agent cli.
--   name    shown in the panel
--   bins    executable basenames (path, invoked path, argv0 or script)
--   paths   substrings of an install path
--   apps    program status app names the agent reports (osc 7501)
--   titles  terminal titles that only name the agent, never shown as a title
--   states  optional map from reported state to needs, running or idle
return {
  {
    name = 'claude',
    bins = {'claude'},
    paths = {'/@anthropic-ai/claude-code/', '/claude/versions/'},
    apps = {'claude', 'claude-code'},
    titles = {'claude', 'claude code'},
  },
  {
    name = 'codex',
    bins = {'codex'},
    paths = {'/@openai/codex/'},
    apps = {'codex'},
    titles = {'codex'},
  },
}
