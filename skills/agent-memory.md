---
name: Agent Memory
description: Persistent 3-tier memory system for AI coding agents
---

# Agent Memory Skill

You have access to Agent Memory — a persistent memory system with 3 tiers (Redis hot → pgvector warm → SQL archive).

## Session Start
Always run at the beginning of your session:
```bash
source .env && bash scripts/cortex-bootstrap <your_agent_name>
```

## Available Commands
- `cortex-bootstrap <name>` — Load full team context (roster, sprints, decisions, lessons, activity)
- `cortex-search <query>` — Search across all memory (decisions, lessons, knowledge, messages)
- `cortex-history --agent <name>` — View chat history
- `cortex-log <agent> <type> <summary>` — Log an event (commit, decision, lesson, bug, blocked, etc.)
- `cortex-state` — Show sprint status and summary counts
- `cortex-roster` — Show registered agents
- `cortex-diagnose` — Check environment health

## Event Types for cortex-log
commit, decision, lesson, started, stopped, blocked, unblocked, bug, handoff, question

## Rules
1. Always run cortex-bootstrap at session start
2. Log important decisions with `cortex-log <name> decision "<summary>"`
3. Log lessons learned with `cortex-log <name> lesson "<summary>"`
4. Search before making architectural decisions: `cortex-search "<topic>"`
