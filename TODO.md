# Inventory Collector — Backlog

## High Priority

- [ ] Rewrite Azure SQL scripts (CreateSQLTableFromJSON_azure.ps1, UpdateSQLTableFromJSON_azure.ps1) — still have the same SQL injection patterns as the old on-prem version. Defer until full rewrite: switch auth to Managed Identity (MSI), reuse SqlHelpers.ps1 via SqlConnection with AccessToken instead of Invoke-SqlCmd, parameterize all queries.

## Medium Priority

- [ ] Add Pester test framework for unit/integration tests
