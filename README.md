# Case File Field Check: Agentforce Employee Agent action

An agent action a rep can run from an Employee Agent: **"are any fields missing in
the files on this case?"** It checks every CSV, TSV, TXT, JSON, PDF, PNG and JPG
file attached to a case. It reports:

- **Missing fields**: required fields that don't appear in the file at all.
- **Empty fields**: fields that are blank, hold a placeholder (`N/A`, `TBD`,
  `null`, `____` ...), or can't be read. Each one comes with its row, line or page.

## How each file type is checked

| File type | Method | Result quality |
|---|---|---|
| CSV, TSV | Parsed in Apex. Handles quoted commas, quoted line breaks and trailing empty cells | Exact and repeatable |
| JSON | Parsed in Apex. Walks nested objects and arrays, e.g. `accounts[].number` | Exact and repeatable |
| TXT with `Label: value` lines | Parsed in Apex as a form | Exact and repeatable |
| TXT laid out as a table (`,` `\t` `\|` `;`) | Detected and parsed as a table | Exact and repeatable |
| TXT free prose, PDF, PNG, JPG | Sent to the `Check_Document_Fields_File` prompt template | AI-read; the agent tells the rep to confirm |
| Anything else (docx, xlsx ...) | Reported as not checked, with the reason | n/a |

**Required Fields input.** If the rep names fields ("Date of Birth, Email,
Signature"), only those are checked, and any that are absent are reported as
missing. If the rep names none, every field in the file is checked for empty
values. Name matching ignores case, spaces and punctuation, so
`date_of_birth` = `Date of Birth` = `DateOfBirth`.

**Values are never returned.** Findings contain field names and locations only.
The one exception is a placeholder token such as `"N/A"`.

**Limits per request:** 10 newest supported files, 3 AI reviews, 1 MB per text
file, 2,000 rows or lines per file. Every limit that is hit shows up in the
result note, so the rep never gets a silent partial result.

## Components

| Type | API name | Purpose |
|---|---|---|
| `ApexClass` | `CaseFileFieldValidator` | The invocable action. Finds the files, routes each one to parsing or AI review, and builds the per-file results and summary |
| `ApexClass` | `CaseFileFieldAnalyzer` | Pure parsing logic for CSV/TSV/TXT/JSON (no SOQL/DML) |
| `ApexClass` | `CaseFileFieldAnalyzerTest`, `CaseFileFieldValidatorTest` | 27 tests, none insert a Case, so they run in SDO orgs |
| `ApexClass` | `CaseFileFieldValidatorCaseTest` | 4 Case-linked tests. **These fail in SDO orgs** (see below) |
| `GenAiPromptTemplate` | `Check_Document_Fields_File` | Flex template: `Attached_File` (File / ContentDocument, GPT-5) + `Required_Fields` (String) → line-format findings |
| `GenAiFunction` | `Check_Case_Files_For_Missing_Fields` | Registers the Apex action for Agent Builder |
| `GenAiPlugin` | `Case_File_Field_Check` | Topic with routing description, scope, and 8 instructions |
| `PermissionSet` | `Agentforce_Case_File_Field_Check` | Apex class access (add `agentAccesses` for your agent) |

### Gotcha: action schema folder layout

The action's schemas must live at `genAiFunctions/<Name>/input/schema.json` and
`genAiFunctions/<Name>/output/schema.json`. A `schema/input.json` layout deploys
**successfully** but the files are silently dropped. The action is then saved
with no schema, and retrieving it fails with `RESOURCE_NOT_FOUND ... an input or
output schema is missing`. Confirmed in sdo26 on 10 Sep 2026 by comparing with
a working action retrieved from the org.

### Gotcha: every output property needs a `description`

With the correct layout in place, an output property without a `description`
fails the deploy with only `An unexpected error occurred ... (59220073)`. Dry-run
probes isolated it: the full schema with every output described deploys; the
same schema missing two output descriptions fails. Input descriptions were
present in every probe, so give every input property a description too.

## Action contract

**Inputs:** `caseId` (record ID *or* case number, and leading zeros are optional),
`fileId` (optional 068/069 ID for a single file), `requiredFields`
(optional, comma-separated).

**Outputs:**
- `status`: `ISSUES_FOUND` / `NO_ISSUES_FOUND` / `NOT_CHECKED`
- `summary`: text for the rep, one line per file
- `filesChecked`, `filesWithIssues`
- `files[]`: `contentVersionId`, `fileName`, `fileType`, `checkMethod`,
  `status`, `missingFields[]`, `emptyFields[]`, `recordsChecked`, `note`

Example summary:

```
1 of 2 checked file(s) have missing or empty fields.
- applicants.csv (parsed): Missing: Date of Birth. Empty: Email - blank in 3 of 120 rows (row 4, row 17, row 88).
- loan-form.pdf (ai review): no missing or empty fields. Document: Loan application, 2 pages. Read by AI, so confirm against the document before contacting the customer.
```

## Status in `chris.mccarthy+sdo26@salesforce.com` (10 Sep 2026)

- **Deployed:** the Apex classes, the prompt template, the action, the topic and the permission set.
  The action was verified by retrieving it back from the org: `input/schema.json`
  (3 inputs) and `output/schema.json` (5 outputs, including the `FileResult`
  list type) are stored. The topic is **not** attached to any agent yet.
- **Tests:** 27/27 pass. Coverage: `CaseFileFieldAnalyzer` 96%, `CaseFileFieldValidator` 80%.
- **Case-linked tests fail in SDO**, as expected. Every Case a test inserts is
  rejected by the org's `SDO Service - Case - On Create` flow
  (`CANNOT_EXECUTE_FLOW_TRIGGER: Missing required input parameter: helperConfig`).
  That isn't a bug in this code, but it will block a production deploy that runs
  those tests until the flow is fixed or bypassed.
- **Smoke test against real data:** ran `caseId = '4965'` on case 00004965.
  It resolved the case number without its leading zeros, found the real PDF
  `remittance-ACH-20260908-4471.pdf`, and called the prompt template. The
  template returned `No active template version`, which the action reported as a
  readable NOT_CHECKED note instead of throwing.
- **Not yet verified:** that the model reads PDF content and follows the line
  format. That needs the template activated (step 1 below).

## Remaining setup (click-only)

1. **Activate the template.** Setup → Prompt Builder → *Check Document Required
   Fields* → **Activate**. A template deployed as `Published` still reports
   "No active template version" until you do this. Until then, PDFs and images
   come back as NOT_CHECKED; CSV/TSV/TXT/JSON work already.
2. **Add the topic to your Employee Agent.** In Agentforce Builder open the agent
   (in sdo26, e.g. *Agentforce Service Assistant* or *Agentforce (Default)*), add
   the **Case File Field Check** topic from the asset library, then save,
   publish, and **activate** (publish doesn't activate).
3. **Grant access to reps:**
   - `Agentforce_Case_File_Field_Check` for Apex class access.
   - An `agentAccesses` block for the agent, as the permission set comment shows.
   - Prompt template run access (*Einstein Prompt Template User* or your org's
     equivalent), otherwise the AI review fails for that user.

## Deploy to another org

On Windows, run `sf` from PowerShell. Supporting metadata goes first, the agent last.

```powershell
sf project deploy start -x manifest/package.xml --test-level RunSpecifiedTests --tests CaseFileFieldAnalyzerTest --tests CaseFileFieldValidatorTest --tests CaseFileFieldValidatorCaseTest -o <username>
```

In an SDO org, leave out `CaseFileFieldValidatorCaseTest` (or use
`--test-level NoTestRun` in a non-production org).

## Test utterances (after activation)

| Utterance | Expected |
|---|---|
| "Are any fields missing in the files on this case?" (on a case record) | Runs with the record ID, no required fields; lists empty fields per file |
| "Check case 4965's documents for a signature and date of birth" | `caseId = 4965`, `requiredFields = "Signature, Date of Birth"` |
| "Does the CSV the customer sent have every email filled in?" | Reports the CSV only; Email blanks with row numbers |
| "What's the account number on the form?" | Declines to repeat values |
| "Email the customer asking for the missing fields" | Lists the missing items; tells the rep to send the request themselves |
| "What's wrong in this error screenshot?" | Does **not** route here |
