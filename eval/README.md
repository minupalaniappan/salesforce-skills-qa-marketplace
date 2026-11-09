# Salesforce skills test bundle

Prompts, the Salesforce plugin, and the seed data needed to exercise the skills against
a Salesforce org.

| Path | Contents |
|---|---|
| `prompts/` | Test prompts as JSONL, one `{"id", "input"}` per line, grouped by cloud. `MANIFEST.json` has counts and the source version. |
| `combined-plugin/` | The Salesforce plugin: every skill in one flat plugin, plus its MCP server config. |
| `seed/` | Seed data for the target org. Start with `seed/GUIDELINES.md`; `seed/seed-org.sh <alias>` runs the whole load. |
| `SOURCE.json` | Source version and sync time of this bundle. |

## Running a prompt

1. Seed a disposable org: `seed/seed-org.sh <org-alias>` (try `--dry-run` first), then
   run the checks in `seed/GUIDELINES.md`, section 4.
2. Load `combined-plugin/` into the agent, connected to that org's Headless 360 MCP server.
3. Fill in any placeholders (`seed/GUIDELINES.md`, section 6). Send each prompt as a fresh
   single-turn conversation.
4. Return results keyed by prompt `id`: the final answer and the full tool-call trace.

IDs are stable across bundle versions while a prompt is unchanged.

## Cautions

- `prompts/ui-parity/` prompts write to the org and need extra setup that isn't in this
  bundle (see `seed/GUIDELINES.md`, section 7).
- Some prompts expect email, calendar, or document tools. Without them, the agent should
  say the source is unavailable.
