# Agent Memory — Step-by-Step Setup Guide

A beginner-friendly guide to setting up Agent Memory on your machine. No prior experience with containers or databases required.

---

## What You're Building

Agent Memory gives your AI coding agent (Claude Code, Codex, Gemini CLI, etc.) the ability to remember things between sessions. When you close a session and start a new one, the agent will know what happened last time — decisions made, lessons learned, tasks assigned.

It works by running two small services on your computer:
- **Redis** — a fast cache (think: short-term memory)
- **PostgreSQL** — a database with search capabilities (think: long-term memory)

Both run inside containers, so they won't mess with anything else on your system.

---

## Step 1: Install a Container Runtime

Containers are like lightweight virtual machines. You need one of these:

### macOS (recommended: Podman)

Open Terminal and run:

```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Podman (free, open-source)
brew install podman

# Start Podman's virtual machine (one-time setup)
podman machine init
podman machine start

# Install Redis CLI (needed for stream operations)
brew install redis
```

### Linux (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install -y podman redis-tools
```

### Windows

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (easiest option)
2. Make sure WSL2 is enabled (Docker Desktop will prompt you)
3. Install Redis CLI via WSL: `sudo apt install redis-tools`

### How to verify it works

```bash
# Should print version info without errors
podman --version    # or: docker --version
redis-cli --version
```

---

## Step 2: Clone the Repository

```bash
# Go to wherever you keep projects
cd ~/Projects

# Clone Agent Memory
git clone https://github.com/a-mad-av8r/agent-memory.git

# Enter the directory
cd agent-memory
```

---

## Step 3: Run Setup

One command does everything:

```bash
bash setup.sh
```

Or, if you want to name your project:

```bash
bash setup.sh my-awesome-project
```

### What setup.sh does (you don't need to do any of this manually):

1. ✅ Detects whether you have Podman or Docker
2. ✅ Starts a Redis container (for fast caching)
3. ✅ Starts a PostgreSQL container with pgvector (for semantic search)
4. ✅ Creates the database
5. ✅ Creates all 16 tables
6. ✅ Sets up Redis Streams (for agent-to-agent awareness)
7. ✅ Writes a `.env` config file
8. ✅ Verifies everything works

You should see green checkmarks (✓) for each step. If you see a red X, the error message will tell you what went wrong.

---

## Step 4: Test It

```bash
# Load the config
source .env

# Run bootstrap for a test agent
bash scripts/cortex-bootstrap test-agent
```

You should see output like:

```
# Agent Cortex — Context for test-agent
Generated: 2026-03-25 14:30:00 | Project: myproject

## Live Events
(No unacknowledged events)

## Team Roster
(No data)

## Active Sprints
(No data)

...

Cortex bootstrap complete. You are test-agent on project myproject.
```

That means everything is working. The data sections are empty because you haven't logged anything yet — that's normal.

---

## Step 5: Use It With Your AI Agent

### Claude Code

Add this to your `CLAUDE.md` file in any project:

```markdown
## Agent Memory
Run at session start:
source /path/to/agent-memory/.env && bash /path/to/agent-memory/scripts/cortex-bootstrap <agent_name>
```

Or copy the skill file:

```bash
cp skills/agent-memory.md ~/.claude/skills/
```

### Codex

Tell Codex in your system prompt:

```
Before starting work, run: source /path/to/agent-memory/.env && bash /path/to/agent-memory/scripts/cortex-bootstrap codex
```

### Gemini CLI

Same approach — add the bootstrap command to your Gemini configuration or system prompt.

---

## Step 6: Log Your First Event

```bash
# Source the config
source .env

# Log a decision
bash scripts/cortex-log phoenix decision "Using TypeScript for the API layer"

# Log a lesson
bash scripts/cortex-log phoenix lesson "Always add --help to CLI scripts"
```

Now start a new bootstrap session — you'll see those events in the context:

```bash
bash scripts/cortex-bootstrap phoenix
```

---

## Daily Usage Cheat Sheet

| What You Want | Command |
|---------------|---------|
| Start a session | `bash scripts/cortex-bootstrap <name>` |
| Search memory | `bash scripts/cortex-search "auth architecture"` |
| Log a decision | `bash scripts/cortex-log <name> decision "summary"` |
| Log a lesson | `bash scripts/cortex-log <name> lesson "summary"` |
| Log a bug | `bash scripts/cortex-log <name> bug "summary"` |
| View history | `bash scripts/cortex-history --agent <name>` |
| Check status | `bash scripts/cortex-state` |
| See agents | `bash scripts/cortex-roster` |
| Health check | `bash scripts/cortex-diagnose` |

---

## Troubleshooting

### "Container runtime not found"
You need Podman or Docker installed. See Step 1.

### "Redis not responding"
```bash
# Check if the container is running
podman ps    # or: docker ps

# If not listed, start it:
podman start mem-redis    # or: docker start mem-redis
```

### "PostgreSQL not responding"
```bash
# Check if the container is running
podman ps    # or: docker ps

# If not listed, start it:
podman start mem-postgres    # or: docker start mem-postgres
```

### "No data" for everything
That's normal on a fresh setup. Run `cortex-log` a few times to add some data, then `cortex-bootstrap` will show it.

### Schema issues after updating
Re-apply the schema (it's safe to re-run):
```bash
podman cp schema.sql mem-postgres:/tmp/schema.sql
podman exec mem-postgres psql -U postgres -d myproject_agent_memory -f /tmp/schema.sql
```

---

## Uninstalling

If you want to remove everything:

```bash
# Stop and remove containers
podman stop mem-redis mem-postgres
podman rm mem-redis mem-postgres

# Remove the repo
rm -rf ~/Projects/agent-memory
```

Your data is stored inside the containers. Removing them deletes all memory data permanently.

---

## Next Steps

- ⭐ Star the repo if it's useful
- 🐛 Open an issue if something breaks
- 📖 Check out [Agent Telepathy](https://github.com/a-mad-av8r/agent-telepathy) — shared awareness between agents (coming soon)
