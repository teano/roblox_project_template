# CodeGraph setup

CodeGraph is local development tooling for code exploration by Codex. It is not
part of the Roblox experience and is not loaded by Rojo or Roblox Studio.

A Git clone alone is intentionally insufficient: the executable belongs to the
developer computer, while the generated graph database belongs to one local
checkout.

## What the repository provides

The repository tracks:

- `.codex/config.toml`, which tells Codex to launch
  `codegraph serve --mcp`;
- `.codegraph/.gitignore`, which prevents the generated database, logs, process
  metadata, and other transient files from being committed;
- this setup guide and the CodeGraph usage rules in `AGENTS.md`.

The repository does not track:

- the CodeGraph executable or its bundled runtime;
- `.codegraph/codegraph.db` or its WAL files;
- a running CodeGraph process.

## Fresh Windows computer

### 1. Install the CLI

The official standalone installer does not require Node.js:

```powershell
irm https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.ps1 | iex
```

Close that terminal and open a new one before continuing because the current
PowerShell session may not see the updated `PATH`.

If Node.js and npm are already installed, the equivalent pinned installation
used to validate this template is:

```powershell
npm install --global @colbymchenry/codegraph@1.5.0
```

Confirm that the command is available:

```powershell
codegraph --version
Get-Command codegraph
```

### 2. Connect CodeGraph to Codex

Configure the current user's Codex installation:

```powershell
codegraph install --target=codex --location=global --yes
```

The repository also contains `.codex/config.toml`, so the expected MCP command
is versioned with the project. The global installation remains useful because
it configures Codex consistently for this and other CodeGraph projects.

### 3. Clone and initialize the project

Clone or create a repository from the template, then build its local index:

```powershell
git clone <repository-url>
cd roblox_project_template
codegraph init
```

`codegraph init` creates `.codegraph/` and builds the first complete index.
Every working copy must run it once; copying another developer's database is
not supported by this project.

### 4. Restart and verify

Restart Codex or open a new Codex task from the project directory, then verify
the CLI:

```powershell
codegraph status
```

The status must report indexed Luau files, nodes, edges, and the `wal` journal
mode. The exact counts change as the template evolves.

Ask Codex to check CodeGraph. A successful check should be able to:

1. return `codegraph_status`;
2. find `Bootstrap.server.luau` and `Bootstrap.client.luau`;
3. return context or callers for a project symbol such as `PlayersModule`.

## Service lifecycle

Codex launches `codegraph serve --mcp` from the project configuration. CodeGraph
starts or attaches to a local per-project daemon and watches file changes while
clients are connected. The daemon may stop after its idle timeout and is
started again automatically on the next request.

There is no Windows service to install, enable, or start manually.

## Daily use

Normally no maintenance command is required. The MCP server watches added,
changed, and deleted files and synchronizes the graph automatically.

Useful diagnostics:

```powershell
codegraph status
codegraph sync
codegraph --version
```

Do not edit `codegraph.db`, its WAL files, daemon logs, or process files
directly.

## Troubleshooting

### `codegraph` is not recognized

Open a new terminal and run:

```powershell
Get-Command codegraph
```

If it is still missing, reinstall the CLI. When using npm, confirm that the npm
global binary directory is present on `PATH`.

### Codex has no `codegraph_*` tools

1. Confirm that `codegraph status` works in the project directory.
2. Confirm that `.codex/config.toml` exists in the clone.
3. Run `codegraph install --target=codex --location=global --yes`.
4. Make sure the repository is trusted in Codex.
5. Restart Codex or open a new task.

To inspect the configuration CodeGraph expects without changing files:

```powershell
codegraph install --print-config codex
```

### CodeGraph reports that the project is not initialized

Run this command from the repository root:

```powershell
codegraph init
```

### Recently changed code is missing

Wait briefly for the file watcher. If the result remains stale, run:

```powershell
codegraph sync
codegraph status
```

CodeGraph supplements the compiler, Rojo, tests, and Studio output. A successful
graph query does not establish that the game builds or behaves correctly.
