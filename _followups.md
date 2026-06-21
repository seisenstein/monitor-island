# Post-workflow follow-ups (apply after redesign workflow completes)

## 1. Smart memory formatter (user request)
- Any per-process / workload / model memory value (currently shown like "2137 MB"):
  if value >= 1024 MB -> show "X.XX GB" (value/1024), else "X.XX MB". ALWAYS 2 decimals.
- Apply to: workload row memory, local-model memory footprint, per-instance memory.
- Keep the unified-memory line (used/total) in GB as-is, but also round to 2 decimals there.
- Add fmtMem(mb: Double) -> String helper; use everywhere a process memory is shown.

## 2. Per-session drill-down for Claude Code (user request)
- "see each claude code session as a standalone if i drill down into it with a dropdown."
- Data: WorkloadEntry gains instances: [WorkloadInstance] { pid, memoryMB, cpuPercent?, label }.
  label = cwd basename if obtainable (proc_pidinfo PROC_PIDVNODEPATHINFO -> cwd path), else "pid N".
- Collect per-pid in WorkloadSampler.sample() (keep the per-pid records, not just the aggregate sum).
- UI: each workload row (esp. "Claude Code xN") gets a disclosure/dropdown; expanded shows one
  sub-row per instance with its label + memory (using fmtMem). Animate the disclosure.
- Applies to Codex / llama-server too where >1 instance.

Both must keep --dump JSON valid (include instances array there too) and build green.
