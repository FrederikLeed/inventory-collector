# Inventory Collector — Backlog

## High Priority

- [ ] Rewrite Azure SQL scripts (CreateSQLTableFromJSON_azure.ps1, UpdateSQLTableFromJSON_azure.ps1): parameterize all queries (currently string-concatenated), switch auth to Managed Identity (MSI), reuse SqlHelpers.ps1 via SqlConnection with AccessToken instead of Invoke-SqlCmd.
