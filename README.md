# ELSAP Agent

PowerShell scripts that talk to the ELSAP web application (the City of Vienna's external time-sheet system) on behalf of the contractor.

The first script, `Get-ElsapHours.ps1`, reads the ordered and open hours of all bookable time sheets, appends them to a history CSV, and shows a desktop notification when anything changed since the previous run.

See [GLOSSARY.md](GLOSSARY.md) for the terms used in the code and documentation.

## Requirements

- PowerShell 7.0 or later (`pwsh`), on Windows or macOS. On macOS: `brew install powershell`.
- An ELSAP account (ADFS user name and password, no second factor).

## Setup

```powershell
pwsh ./Setup-Elsap.ps1
```

The setup script asks for the ELSAP user name and password, tests the login, stores the credential in the OS credential store and registers the scheduled job. The password never touches the file system.

| | Windows | macOS |
|---|---|---|
| Credential store | Credential Manager, target `ELSAP` | Keychain, service `ELSAP` |
| Schedule | Task Scheduler task `ELSAP Hours Check` | LaunchAgent `local.elsap-agent` |
| Notification | Toast (via Windows PowerShell 5.1) | `osascript` notification |

The job runs at logon and daily at 09:00 (change with `-DailyAt`). It only runs while the user is logged on. The script itself skips a run if one already succeeded today, so repeated logons do not cause repeated requests.

## Usage

```powershell
pwsh ./Get-ElsapHours.ps1          # normal run (skipped if already done today)
pwsh ./Get-ElsapHours.ps1 -Force   # run now, ignore the once-per-day guard
```

## Output

Everything is written to `data/` (git-ignored):

| File | Content |
|---|---|
| `elsap-hours.csv` | History. One row per time sheet and run. Semicolon-separated, UTF-8 with BOM, decimal comma, so Excel with Austrian or German locale opens it directly. Columns: `Timestamp;Order;Item;Service;Project;Role;Period;Ordered;Open` |
| `last-success.txt` | Timestamp of the last successful run. Marks which CSV rows form the previous snapshot. |
| `elsap.log` | One line per run: skipped, baseline, changes, or error. |

A time sheet is identified by `Order/Item/Service` (the position key). Project and role are descriptive text.

## Change detection

Each run is compared with the previous successful run. A notification is shown when a time sheet appeared, disappeared, or its ordered or open hours differ (month changes are ignored). The first run only records the baseline and stays silent. If a run fails, the CSV is not touched and an error notification is shown, so an outage is never mistaken for "no change".

## How it works

ELSAP is an SAP UI5 app backed by an OData service. There is no browser automation. `Connect-Elsap` replays the sign-in:

1. `GET` the app, which answers with an auto-submitted SAML request for ADFS.
2. `POST` it to ADFS and read the forms-login page.
3. `POST` user name and password (`AuthMethod=FormsAuthentication`).
4. `POST` the returned SAML response to SAP, which sets the session cookies.

Then one `GET` on `LeistungsblattSet` returns all time sheets as JSON. Bookable means `Elikz`, `Loekz` and `Erekz` are all false (this matches the "Bebuchbar" tab in the UI). `Pstd` is the ordered hours, `Ostd` the open hours.

## Layout

```
Get-ElsapHours.ps1   daily run
Setup-Elsap.ps1      one-time credential and schedule setup
src/Elsap.psm1       login, data access, credential store, notification, diffing
data/                CSV, state, log (git-ignored)
scratch/             captures and drafts (git-ignored)
```
