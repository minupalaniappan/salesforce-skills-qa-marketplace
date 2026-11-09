# Seeding guidelines

This guide describes the Salesforce org state the prompts in `prompts/` are written
against, and how to build it from the files in `seed/`. It is written for an agent that
can run the `sf` CLI against the target org.

**Shortcut:** `seed/seed-org.sh <org-alias>` runs the whole load order in section 2,
detects a complete or partial fixture, and is safe to re-run. Use `--dry-run` to print
the commands first, and `--no-address-settings` to skip S0. The rest of this guide
explains what the script does and how to check the result.

Paths below are relative to `seed/`:

| Path | Contents |
|---|---|
| `seed-org.sh` | Runs the load order below against an authenticated `sf` alias |
| `core/sfdx-project.json` | SFDX project file, so `sf` commands run from `core/` |
| `core/force-app/main/default/objects/`, `permissionsets/` | Custom schema and the `H360_Test_Data` permission set |
| `core/data/plan.json` and the record files it lists | Sales rows, imported with `sf data import tree` |
| `core/data/marketing-plan.json` and its record files | Marketing Campaign fixture |
| `core/scripts/*.apex` | Post-import steps that tree import can't express |
| `core/config/project-scratch-def.json` | Scratch-org definition, if you create a scratch org |
| `address-settings/` (optional) | State and Country picklist values, for orgs with address picklists on |
| `supplemental-marketing/` (optional) | Extra Campaigns, Leads and members named in marketing prompts |

## 0. Rules (read first)

- **Only seed a disposable org**, such as a Developer Edition org or a scratch org.
  Confirm with `sf org display` that it is not production and not shared.
- **Accept only an empty org or a complete fixture.** If you find part of a fixture, stop
  and reset it before reseeding. Never patch partial state by hand, and never delete
  records outside the exact fixture names in this guide.
- **Fail on duplicates.** If a fixture name matches more than one record, stop. Don't pick one.
- **Never create or rename Users.** Use the org's running user as-is.
- **Never activate the Contract.** It stays `Draft`.
- **Keep credentials out of logs.** Never print auth URLs, client secrets, or access tokens.

## 1. Prerequisites

1. An authenticated `sf` CLI alias for the target org (`sf org display -o <alias>` shows Connected).
2. Lightning enabled, single currency, and no Opportunity RecordTypes. Picklists must use
   the master value set. Don't enable multi-currency.
3. The standard pricebook can start inactive. Step S4a activates it.
4. Run every command below from `seed/core/` unless it says otherwise.

## 2. Load order

Run the steps in this order. Each depends on the one before it.

| # | Step | Command |
|---|---|---|
| S0 | Address picklist values, so `BillingCountry = "USA"` and `BillingState = "CA"`/`"TX"` import when State and Country picklists are on. `seed-org.sh` runs it by default; skip with `--no-address-settings` | from `seed/`: `sf project deploy start --metadata-dir address-settings -o <alias> --wait 20` |
| S1 | Deploy schema | `sf project deploy start --source-dir force-app/main/default/objects --source-dir force-app/main/default/permissionsets -o <alias>` |
| S2 | Assign permission set | `sf org assign permset --name H360_Test_Data -o <alias>` (already assigned is fine) |
| S3 | Import Sales rows | `sf data import tree --plan data/plan.json -o <alias>` |
| S4a | Products, pricebook, line items | `sf apex run --file scripts/seed-products-pricebook.apex -o <alias>` |
| S4b | Email messages and file | `sf apex run --file scripts/seed-communications.apex -o <alias>` |
| S4c | History and current-week events (**always last**) | `sf apex run --file scripts/trigger-opp-history.apex -o <alias>` |
| M1 | Marketing User permission | Set `UserPermissionsMarketingUser = true` on the running user (an update, not a new User) |
| M2 | Marketing Campaigns | `sf data import tree --plan data/marketing-plan.json -o <alias>` |
| M3 | Supplemental Campaigns (optional) | from `seed/supplemental-marketing/`: `sf data import tree --plan plan.json -o <alias>` |

S4c is idempotent. Re-run it at the start of every test day, because it moves the
current-week events to the current week. The other steps run once per org.

### The import cycle (do not reorder `plan.json`)

`Opportunity.Primary_Risk__c` points to `Deal_Risk__c`, and `Deal_Risk__c.Opportunity__c`
points back. `plan.json` breaks the loop by splitting Deal_Risk into two files that straddle
Opportunities:

```
Account (parent) → Account (child)
→ Deal_Risk__c (primary, no Opportunity__c)
→ Opportunity (sets Primary_Risk__c)
→ Deal_Risk__c (child, sets Opportunity__c)
→ Contact → OpportunityContactRole → Task → Event → Case → Contract → Note → Lead
```

Records link by `@referenceId` only. Don't add Salesforce IDs, and don't add comment keys
to records. The Tree API rejects unknown keys and fails the whole import.

## 3. Required state

These are the counts and anchors. Exact field values are in the record files.

**Accounts**
- `Joja Corporation`, the anchor account.
- `Pierre's General Store`, a second account with its own opportunity and one contact.
- `JojaMart Pelican Town`, a child of Joja via `ParentId`.

**Opportunities (6)**

| Name | Stage | Amount |
|---|---|---|
| Joja Corporation - Warehouse Automation Platform | Negotiation/Review (80%) | 250,000 |
| Joja Corporation - JojaCola Analytics Expansion | Prospecting | 120,000 |
| Joja Corporation - Membership Renewal FY27 | Value Proposition (60%) | 91,000 |
| Pierre's General Store - Initial Rollout | Qualification | 75,000 |
| Joja Corporation - Community Center Pilot | Closed Won | 60,000 |
| Joja Corporation - Legacy Register Migration | Closed Lost | 40,000 |

The Warehouse Automation opportunity is the anchor. Its `Primary_Risk__c` points to the
pricing risk.

**Deal risks (4 `Deal_Risk__c`)**
- A pricing risk on the anchor, linked as `Primary_Risk__c`.
- A champion risk (Critical) and a legal risk (Medium) on the anchor.
- A renewal-budget risk (Medium) on the renewal opportunity.

**People**
- Four Contacts, including `Morris Grey` (Regional Manager at Joja), a CFO, and an IT Ops
  contact at Joja, plus one Pierre's contact.
- Three contact roles on the anchor: Decision Maker (Morris, primary), Economic Buyer,
  and Technical Buyer.

**Activity**
- Six Tasks in mixed statuses. One is on the renewal opportunity and one is account-level
  on Joja.
- Three Events: `Joja QBR` and `Follow-up with Morris` on the anchor, and `Joja FY27 renewal
  review` on the renewal opportunity.
- After S4c, `Joja QBR` is on Wednesday at 10:00 Pacific and `Follow-up with Morris` is on
  Friday at 09:00 Pacific, both in the current week.
- S4c also creates the `H360 Eval Weekly …` opportunities and events for the current week.
  It never deletes earlier weeks' records.
- One Note on the anchor, two Cases on Joja (Working and New), and one Draft Contract.

**Leads**: Marnie's Ranch, Robin's Carpentry, and Stardrop Saloon. Leave them unconverted.

**Products (S4a)**
- The standard pricebook is active.
- `H360-PLAT` (Warehouse license, 50,000) has line items on the expansion and pilot
  opportunities.
- `H360-ANALYTICS` (90,000) is catalog-only. Never add it to a Joja opportunity.

**Communications (S4b)**: two EmailMessages on the anchor (a pricing proposal and Joja's
reply), and one file, "JojaCola Pricing Proposal", shared to the anchor.

**Marketing (M2)**: five Campaigns named `H360 Eval Campaign In Progress`,
`H360 Eval Ambiguous Campaign Alpha`, `H360 Eval Ambiguous Campaign Beta`,
`H360 Eval BriefId Fallback Campaign`, and `H360 Eval Completed Response Rate Campaign`.
The last one has eight Lead members.

**Supplemental marketing (M3)**: `Summer Adventure` (with child `Summer Adventure
Re-engagement`), `Velocity Road 2 Launch`, `Spring Launch`, `Holiday Campaign 2026`, and
`Black Friday Launch`, plus ten Leads and their members.

**Deliberately absent**: VoiceCall, VideoCall, AccountPlan, BotVersion, field history
tracking, extra Users, and direct reports for the running user. Prompts that touch these
expect the feature to be unavailable or empty, so don't add them.

## 4. Check the seed before handing over

All of these are read-only queries.

1. Counts: 3 Accounts (2 top-level, 1 child), 6 named Opportunities, 4 Contacts, 3 Leads,
   3 named Events, 4 Deal risks, 3 contact roles on the anchor.
2. The anchor has `Primary_Risk__c` set. The renewal amount is 91,000.
3. Morris is the primary Decision Maker on the anchor.
4. `Joja QBR` and `Follow-up with Morris` fall in the current Pacific week, on the weekdays
   and times above.
5. The standard pricebook is active, and only `H360-PLAT` has line items.
6. Each fixture name matches exactly one record.
7. The marketing fixture has 5 Campaigns and 8 members on the completed campaign.

If any check fails, report it rather than repairing it.

## 5. Re-seeding

- **Empty org:** run S0 through M3.
- **Complete fixture present:** re-run only S4c, then check.
- **Partial fixture:** stop and report. Reset only the exact fixture records, then reseed.

## 6. Prompt placeholders

Some prompts refer to the org's running user. Before sending them, replace:

| Placeholder | Replace with |
|---|---|
| `{{RUNNING_USER_NAME}}` | the running user's full name |
| `{{RUNNING_USER_EMAIL}}` | the running user's email address |
| `{{RUNNING_USER_USERNAME}}` | the running user's username |

## 7. What this bundle does not cover

- **Email, calendar, and document connectors.** Some prompts expect inbox, calendar, or
  document search tools. Their content is not Salesforce data and is not included.
- **UI-parity prompts** (`prompts/ui-parity/`). Each folder needs extra setup: an admin,
  a manager and two seller users, Opportunity layouts and Lightning pages, field
  permissions, and in one case a second org. That setup is not in this bundle. These
  prompts also write to the org, so only run them against a disposable org.
