# Salesforce Skills (QA) marketplace

A Cursor plugin marketplace for testing Salesforce's Headless 360 skills in Grok Bot before they go to the public marketplace.

| Path | Contents |
|---|---|
| `plugins/salesforce-skills-qa/` | The plugin: Salesforce's skills plus the Headless 360 MCP server with admin-set OAuth (Consumer Key and Secret) |
| `eval/` | Salesforce's eval bundle: test prompts, org seed data, and its README |

## Setup

1. A team admin imports this repo in the Cursor dashboard under Plugins, Team Marketplaces, Import from Repo, and sets the plugin to Default Off.
2. The admin sets the Salesforce MCP URL, Consumer Key and Consumer Secret on the plugin, from the External Client App in the org under test.
3. Testers turn off the public Salesforce (Headless 360, Beta) plugin, add Salesforce Skills (QA), and sign in to Salesforce.

## Running the evals

Follow `eval/README.md`: seed the org, send each prompt in a new chat, and return the final answer and tool calls keyed by prompt id.

Source: Salesforce skills eval package `beb1d07643fb` (see `eval/SOURCE.json`).
