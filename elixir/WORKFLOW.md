---
tracker:
  kind: memory
  endpoint: null
  api_key: null
  project_slug: null
  active_states: [Todo]
  terminal_states: [Done]
polling:
  interval_ms: 30000
workspace:
  root: "/tmp"
codex:
  command: "codex app-server"
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
  max_total_tokens: 0
  max_no_diff_tokens: 0
mcp_preflight:
  cloudflare:
    required: true
---
Prompt
