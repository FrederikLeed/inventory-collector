# Inventory Collector — Backlog

## High Priority

- [ ] Rewrite Azure SQL scripts (CreateSQLTableFromJSON_azure.ps1, UpdateSQLTableFromJSON_azure.ps1) — still have the same SQL injection patterns as the old on-prem version. Defer until full rewrite: switch auth to Managed Identity (MSI), reuse SqlHelpers.ps1 via SqlConnection with AccessToken instead of Invoke-SqlCmd, parameterize all queries.
- [ ] Hardcoded server names/paths — move defaults to a shared config or make parameters mandatory

## Medium Priority

- [ ] Connection strings in config.xml are plain text — consider Windows credential store
- [ ] UserProfileList: Get-ChildItem -Recurse for profile size is very slow — consider using robocopy /L or WMI Win32_Directory
- [ ] gpresult /r in Get-SystemInfo can hang — add timeout with Start-Job
- [ ] ParseInventory.ps1 / ParseTranscripts.ps1: review for similar issues
- [ ] Add Pester test framework for unit/integration tests

## Low Priority

- [ ] AutoRunInfo logging is per-item instead of per-collection
- [ ] Metrics list is a here-string split by newlines — use a simple array
- [ ] Remove -CimSession comment from Get-ScheduledTasks (line 478)
- [ ] Zip workflow creates intermediate zips then combines — simplify to single zip
