# Platform agents

This repository is the platform Argo CD source. Workload Helm charts live in `ThriftyStack/applications`.

## Documentation in Notion

Notion is the source of truth for ThriftyStack documentation. Leave the GitHub repository `ThriftyStack/docs` unchanged.

Before you change behavior in this repository, read the Notion page that covers that behavior.

In the same task, update that page. If no page covers the change, add one under the section in the table below. On every page you change, keep that page's footer. Write it as `Last updated by: <person or agent> — <what changed>, YYYY-MM-DD`. The name is the person, or Claude Code, Codex, or Cursor. If the page has no footer, add that line at the bottom of the page. For example, `Last updated by: Grok Bot — initial migration from GitHub, 2026-10-21`.

Record a new decision as a new page under [ADRs](https://www.notion.so/400972443c708169b262e47f7c9c56e0).

Never put secrets in Notion. Secrets include tokens, kubeconfigs, recovery shares, private keys, and NetBird setup keys.

### Pages for this repository

Read the page that matches the change, then update that same page.

| Page | Update it when the change touches |
| --- | --- |
| [ThriftyStack Docs](https://www.notion.so/400972443c7081fd83efd3e8710fc9a6) | The docs root. Start here when no row below matches. |
| [Vault](https://www.notion.so/400972443c70813db431fc0bc32215e2) | `infrastructure/charts/vault`, `infrastructure/configuration/vault-provider`, `vault-pki`, `vault-issuer`, or ceremony stages `vault`, `pki`, or `certificates`. |
| [NetBird](https://www.notion.so/400972443c70815fb7b7db1baf120d43) | `infrastructure/charts/netbird` or `clusters/management/overrides/netbird.yaml`. |
| [Disaster Recovery](https://www.notion.so/400972443c70814e9ebccf1806f12504) | Recovery shares, break-glass Vault recovery, or the protected Vault storage binding. |
| [Authentik](https://www.notion.so/400972443c7081d2885dcba7e839fedf) | Identity for this platform, including Authentik. Update this page when the change affects that dependency. Leave it unchanged for Vault, NetBird, mesh, and ceremony edits that do not change identity. |
| [Systems](https://www.notion.so/400972443c7081658761c83b9fc2de16) | A new system. Add the new page under Systems. Systems is the parent of Authentik, Vault, and NetBird. |
| [ADRs](https://www.notion.so/400972443c708169b262e47f7c9c56e0) | A new decision. Add the ADR here. |

Notion MCP can open a page only when the signed-in member can open it. Share [ThriftyStack Docs](https://www.notion.so/400972443c7081fd83efd3e8710fc9a6) with every person who uses these agents.

### Notion MCP setup

The hosted server is `https://mcp.notion.com/mcp`. The files below name that server and contain no tokens. Each person completes OAuth once per tool. The login stays on that person's machine. A workspace guest cannot complete Notion OAuth. Use a workspace member account.

#### Cursor

The project file is `.cursor/mcp.json`.

1. Open this repository in Cursor.
2. Open Customize in the sidebar.
3. Enable Notion.
4. Complete the OAuth login.
5. Run `agent mcp list`.
6. Check that `notion` is connected.
7. Check that its source is the project.

From a terminal, `agent mcp login notion` starts the same OAuth login. Then run `agent mcp enable notion`. Check again with `agent mcp list`.

#### Claude Code

The project file is `.mcp.json`. The server `type` is `http`.

Do not run `claude mcp add` for Notion. That command writes a second entry. This file is the project server.

1. Open this repository in Claude Code.
2. Approve the `notion` server if Claude Code asks.
3. Run `claude mcp login notion`.
4. Complete the OAuth login.
5. Run `claude mcp list`.
6. Check that `notion` is connected.

Inside a session, `/mcp` lists the same servers and can start the same login.

#### Codex

The project file is `.codex/config.toml`. The server table is `[mcp_servers.notion]`.

Codex loads that file only after you trust the project. Trust the project before login.

Do not run `codex mcp add` for Notion. That command writes the user config at `~/.codex/config.toml`.

1. Trust this project in Codex.
2. From the repository root, run `codex mcp login notion`.
3. Complete the OAuth login.
4. Run `codex mcp list`.
5. Check that `notion` is listed.

In the Codex TUI, `/mcp` shows the connected servers.
