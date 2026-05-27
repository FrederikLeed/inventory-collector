Param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,
    [Parameter(Mandatory=$true)]
    [string]$Database,
    [Parameter(Mandatory=$true)]
    [string]$JsonFilesPath,
    [Parameter(Mandatory=$true)]
    [string]$logFilePath
)

# PowerShell Script to Update SQL Tables from JSON Files

# Dot-source shared SQL helpers
. (Join-Path -Path $PSScriptRoot -ChildPath "SqlHelpers.ps1")

# Streaming JSON reader for InstalledUpdates. Exposes one row at a time as
# IDataReader so SqlBulkCopy can pump it straight to SQL without ever
# materialising the full array. Memory is bounded by the bulk-copy batch
# (~3 MB), regardless of JSON file size.
# Guard against re-add when the script is invoked multiple times in one PS
# session (Add-Type would otherwise fail with "type already exists").
if (-not ('InstalledUpdatesJsonReader' -as [type])) {
# Build the C# reader. Production runs Windows PowerShell 5.1 (.NET
# Framework); the type compiles cleanly there. Under PowerShell 7+ the BCL
# layout differs and System.Web.Extensions (JavaScriptSerializer) may not
# resolve - swallow the error and let Import-InstalledUpdatesDifferential
# fall back to the slower in-PS DataTable path.
try {
Add-Type -ReferencedAssemblies System.Data, System.Xml, System.Web.Extensions -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

public class InstalledUpdatesJsonReader : IDataReader {
    static readonly string[] Names = { "ComputerName", "Title", "InstalledOn", "ServiceID", "RunId" };
    static readonly Type[]   Types = { typeof(string), typeof(string), typeof(DateTime), typeof(string), typeof(Guid) };

    StreamReader            _src;
    JavaScriptSerializer    _jss;
    Dictionary<string,object> _cur;
    bool _closed;
    long _rowsRead;

    public InstalledUpdatesJsonReader(string path) {
        _src = new StreamReader(path);
        _jss = new JavaScriptSerializer();
        _jss.MaxJsonLength  = int.MaxValue;
        _jss.RecursionLimit = 100;
        // Skip past the opening '['
        int c;
        while ((c = _src.Read()) != -1 && c != '[') { }
    }

    public long RowsRead { get { return _rowsRead; } }

    public bool Read() {
        while (!_closed) {
            int c;
            // Skip whitespace and commas between elements
            while ((c = _src.Peek()) != -1 && (c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r')) _src.Read();
            if (c == -1 || c == ']') { _closed = true; return false; }
            if (c != '{') { _closed = true; return false; }

            // Read one balanced object, respecting string boundaries and escapes
            var sb = new StringBuilder(512);
            int depth = 0;
            bool inString = false;
            bool escape   = false;
            while ((c = _src.Read()) != -1) {
                sb.Append((char)c);
                if (escape) { escape = false; continue; }
                if (inString) {
                    if (c == '\\') escape = true;
                    else if (c == '"') inString = false;
                    continue;
                }
                if (c == '"') { inString = true; continue; }
                if (c == '{') depth++;
                else if (c == '}') {
                    depth--;
                    if (depth == 0) break;
                }
            }
            if (depth != 0) { _closed = true; return false; }

            var d = _jss.DeserializeObject(sb.ToString()) as Dictionary<string, object>;
            if (d == null) continue;
            object cn, title, runId;
            if (!d.TryGetValue("ComputerName", out cn) || cn == null) continue;
            if (!d.TryGetValue("Title",        out title) || title == null) continue;
            if (!d.TryGetValue("RunId",        out runId) || runId == null) continue;
            _cur = d;
            _rowsRead++;
            return true;
        }
        return false;
    }

    public int    FieldCount      { get { return Names.Length; } }
    public string GetName(int i)  { return Names[i]; }
    public Type   GetFieldType(int i) { return Types[i]; }
    public int    GetOrdinal(string name) {
        for (int i = 0; i < Names.Length; i++) if (Names[i] == name) return i;
        return -1;
    }
    public string GetDataTypeName(int i) { return Types[i].Name; }

    public object GetValue(int i) {
        if (_cur == null) return DBNull.Value;
        switch (i) {
            case 0: return _cur["ComputerName"];
            case 1: return _cur["Title"];
            case 2: {
                object raw = null; object tmp;
                if (_cur.TryGetValue("Date", out tmp) && tmp != null) raw = tmp;
                else if (_cur.TryGetValue("InstalledOn", out tmp) && tmp != null) raw = tmp;
                if (raw is string) {
                    DateTime p;
                    return DateTime.TryParse((string)raw, out p) ? (object)p.Date : DBNull.Value;
                }
                if (raw is DateTime) return ((DateTime)raw).Date;
                return DBNull.Value;
            }
            case 3: {
                object s;
                if (_cur.TryGetValue("ServiceID", out s) && s != null) return s;
                return DBNull.Value;
            }
            case 4: return Guid.Parse((string)_cur["RunId"]);
        }
        return DBNull.Value;
    }

    public bool IsDBNull(int i) { return GetValue(i) == DBNull.Value; }
    public int  GetValues(object[] values) {
        int n = Math.Min(values.Length, FieldCount);
        for (int i = 0; i < n; i++) values[i] = GetValue(i);
        return n;
    }

    public object this[int i]      { get { return GetValue(i); } }
    public object this[string nm]  { get { return GetValue(GetOrdinal(nm)); } }

    // Strongly-typed accessors (SqlBulkCopy uses GetValue, these are required
    // by the interface but mostly forward to GetValue with a cast).
    public bool     GetBoolean(int i)  { return (bool)GetValue(i); }
    public byte     GetByte(int i)     { return (byte)GetValue(i); }
    public char     GetChar(int i)     { return (char)GetValue(i); }
    public DateTime GetDateTime(int i) { return (DateTime)GetValue(i); }
    public decimal  GetDecimal(int i)  { return (decimal)GetValue(i); }
    public double   GetDouble(int i)   { return (double)GetValue(i); }
    public float    GetFloat(int i)    { return (float)GetValue(i); }
    public Guid     GetGuid(int i)     { return (Guid)GetValue(i); }
    public short    GetInt16(int i)    { return (short)GetValue(i); }
    public int      GetInt32(int i)    { return (int)GetValue(i); }
    public long     GetInt64(int i)    { return (long)GetValue(i); }
    public string   GetString(int i)   { return (string)GetValue(i); }
    public long GetBytes(int i, long o, byte[] b, int bo, int l) { return 0; }
    public long GetChars(int i, long o, char[] b, int bo, int l) { return 0; }
    public IDataReader GetData(int i) { return null; }

    public int  Depth           { get { return 0; } }
    public bool IsClosed        { get { return _closed; } }
    public int  RecordsAffected { get { return -1; } }
    public DataTable GetSchemaTable() { return null; }
    public bool NextResult()    { return false; }
    public void Close()         { _closed = true; Dispose(); }
    public void Dispose() { if (_src != null) { _src.Dispose(); _src = null; } }
}
"@
} catch {
    Write-Warning "InstalledUpdatesJsonReader type compile failed under $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion); InstalledUpdates load will fall back to in-PS DataTable."
}
}


$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Script-scoped error flag - any per-record or outer catch below sets this;
# final exit code uses it so the scheduler's step gating actually breaks the
# chain on failure instead of always returning success.
$script:hasErrors = $false

# Natural-key map is defined in SqlHelpers.ps1; access via Get-NaturalKey.


# Load the per-run metadata aggregated by ParseInventory.ps1. Upserts
# dbo.Computers (LastSeenAt, LastRunId) and inserts new rows into
# dbo.CollectionRuns, skipping RunIds that already exist (idempotent).
function Import-CollectionRunsJson {
    param (
        [string]$JsonFilePath
    )

    if (-not (Test-Path $JsonFilePath)) { return }

    # ConvertFrom-Json auto-converts ISO 8601 strings to [DateTime]. Locale-
    # sensitive [DateTime]::Parse round-trips on the formatted-string output
    # blow up under non-en-US cultures, so always accept the [DateTime] as-is
    # and only Parse (with InvariantCulture) when the field arrived as a
    # string for some reason.
    function ConvertTo-DateTimeOrDefault {
        param($Value, $Default)
        if ($null -eq $Value) { return $Default }
        if ($Value -is [DateTime]) { return $Value }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
            return [DateTime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return [DateTime]$Value
    }

    try {
        $runs = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        if (-not ($runs -is [System.Array])) { $runs = @($runs) }

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()
            $SqlCommand = $SqlConnection.CreateCommand()

            foreach ($run in $runs) {
                if (-not $run.RunId -or -not $run.ComputerName) { continue }

                # Upsert Computers
                $SqlCommand.Parameters.Clear()
                $SqlCommand.CommandText = @"
MERGE dbo.Computers AS target
USING (SELECT @cn AS ComputerName, @rid AS RunId, @loadedAt AS LoadedAt) AS source
ON (target.ComputerName = source.ComputerName)
WHEN MATCHED THEN
    UPDATE SET LastSeenAt = source.LoadedAt, LastRunId = source.RunId, IsActive = 1, DeactivatedAt = NULL
WHEN NOT MATCHED THEN
    INSERT (ComputerName, FirstSeenAt, LastSeenAt, LastRunId)
    VALUES (source.ComputerName, source.LoadedAt, source.LoadedAt, source.RunId);
"@
                $SqlCommand.Parameters.AddWithValue('@cn',  $run.ComputerName) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@rid', [System.Guid]::Parse([string]$run.RunId)) | Out-Null
                $loadedAt = ConvertTo-DateTimeOrDefault -Value $run.CompletedAt -Default ([DateTime]::UtcNow)
                $SqlCommand.Parameters.AddWithValue('@loadedAt', $loadedAt) | Out-Null
                $SqlCommand.ExecuteNonQuery() | Out-Null

                # Insert into CollectionRuns if RunId is new
                $SqlCommand.Parameters.Clear()
                $SqlCommand.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM dbo.CollectionRuns WHERE RunId = @rid)
INSERT INTO dbo.CollectionRuns
    (RunId, ComputerName, StartedAt, CompletedAt, Status, MetricsSucceeded, MetricsFailed, FailedMetrics, LoadedAt)
VALUES
    (@rid, @cn, @started, @completed, 'Loaded', @ms, @mf, @fm, SYSUTCDATETIME());
"@
                $SqlCommand.Parameters.AddWithValue('@rid', [System.Guid]::Parse([string]$run.RunId)) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@cn',  $run.ComputerName) | Out-Null
                $started   = ConvertTo-DateTimeOrDefault -Value $run.StartedAt   -Default ([DateTime]::UtcNow)
                $completed = ConvertTo-DateTimeOrDefault -Value $run.CompletedAt -Default $started
                $SqlCommand.Parameters.AddWithValue('@started',   $started)   | Out-Null
                $SqlCommand.Parameters.AddWithValue('@completed', $completed) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@ms', $(if ($null -ne $run.MetricsSucceeded) { [int]$run.MetricsSucceeded } else { [DBNull]::Value })) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@mf', $(if ($null -ne $run.MetricsFailed)    { [int]$run.MetricsFailed }    else { [DBNull]::Value })) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@fm', $(if ($run.FailedMetrics) { [string]$run.FailedMetrics } else { [DBNull]::Value })) | Out-Null
                $SqlCommand.ExecuteNonQuery() | Out-Null
            }

            Write-Host "CollectionRuns imported: $($runs.Count) run(s)"
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "Error importing CollectionRuns from $JsonFilePath : $_"
    }
}

function Import-InstalledUpdatesDifferential {
    param([Parameter(Mandatory)][string]$JsonFilePath)

    if (-not (Test-Path $JsonFilePath)) { return }

    # Assumes one RunId per ComputerName per load. Multi-RunId batches still
    # work but the "uninstalled" sweep collapses to whichever RunId SQL joins
    # last per Computer - load batches sequentially if you need deterministic
    # multi-run handling.

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()
        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandTimeout = 1800

        $SqlCommand.CommandText = @"
CREATE TABLE #StageIU (
    ComputerName NVARCHAR(128)    NOT NULL,
    Title        NVARCHAR(512)    NOT NULL,
    InstalledOn  DATE             NULL,
    ServiceID    NVARCHAR(64)     NULL,
    RunId        UNIQUEIDENTIFIER NOT NULL
);
CREATE INDEX IX_StageIU_CN ON #StageIU (ComputerName);
"@
        $SqlCommand.ExecuteNonQuery() | Out-Null

        # Prefer the C# streaming reader (memory bounded by the bulk-copy
        # batch). On runtimes where the helper failed to compile, fall back
        # to materialising a DataTable in PowerShell - slower and uses more
        # RAM at scale, but works everywhere.
        $bulk   = New-Object System.Data.SqlClient.SqlBulkCopy($SqlConnection)
        $rowCount = 0
        try {
            $bulk.DestinationTableName = '#StageIU'
            $bulk.BatchSize            = 10000
            $bulk.BulkCopyTimeout      = 1800
            foreach ($name in 'ComputerName','Title','InstalledOn','ServiceID','RunId') {
                $bulk.ColumnMappings.Add($name, $name) | Out-Null
            }

            if ('InstalledUpdatesJsonReader' -as [type]) {
                $reader = New-Object InstalledUpdatesJsonReader($JsonFilePath)
                try {
                    $bulk.WriteToServer($reader)
                    $rowCount = $reader.RowsRead
                } finally {
                    $reader.Dispose()
                }
            } else {
                $dt = New-Object System.Data.DataTable
                foreach ($spec in @(
                    @{N='ComputerName';T=[string]}, @{N='Title';T=[string]},
                    @{N='InstalledOn';T=[DateTime]}, @{N='ServiceID';T=[string]},
                    @{N='RunId';T=[Guid]})) {
                    $dc = New-Object System.Data.DataColumn($spec.N, $spec.T)
                    $dc.AllowDBNull = $true
                    $dt.Columns.Add($dc) | Out-Null
                }
                $json = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
                if (-not ($json -is [System.Array])) { $json = @($json) }
                foreach ($Item in $json) {
                    if (-not $Item -or -not $Item.ComputerName -or -not $Item.Title -or -not $Item.RunId) { continue }
                    $row = $dt.NewRow()
                    $row['ComputerName'] = [string]$Item.ComputerName
                    $row['Title']        = [string]$Item.Title
                    $rawDate = if ($Item.PSObject.Properties.Name -contains 'Date') { $Item.Date }
                               elseif ($Item.PSObject.Properties.Name -contains 'InstalledOn') { $Item.InstalledOn }
                               else { $null }
                    $row['InstalledOn'] = [DBNull]::Value
                    if ($rawDate) { try { $row['InstalledOn'] = ([DateTime]::Parse([string]$rawDate)).Date } catch { } }
                    $row['ServiceID'] = if ($Item.ServiceID) { [string]$Item.ServiceID } else { [DBNull]::Value }
                    $row['RunId']     = [Guid]::Parse([string]$Item.RunId)
                    $dt.Rows.Add($row); $rowCount++
                }
                if ($rowCount -gt 0) { $bulk.WriteToServer($dt) }
            }
        } finally {
            $bulk.Close()
        }
        if ($rowCount -eq 0) { return }

        # Set-based MERGE - GROUP BY de-dupes duplicate (Computer, Title) within
        # the staging table so SQL Server's "MERGE source must be unique" rule
        # holds.
        $SqlCommand.CommandText = @"
MERGE dbo.InstalledUpdates WITH (HOLDLOCK) AS t
USING (
    SELECT ComputerName, Title,
           MAX(InstalledOn) AS InstalledOn,
           MAX(ServiceID)   AS ServiceID,
           MAX(RunId)       AS RunId
    FROM #StageIU
    GROUP BY ComputerName, Title
) AS s
ON (t.ComputerName = s.ComputerName AND t.Title = s.Title)
WHEN MATCHED THEN
    UPDATE SET LastSeenRunId = s.RunId,
               LastSeenAt    = SYSUTCDATETIME(),
               UninstalledAt = NULL,
               InstalledOn   = COALESCE(t.InstalledOn, s.InstalledOn),
               ServiceID     = COALESCE(t.ServiceID,   s.ServiceID)
WHEN NOT MATCHED THEN
    INSERT (ComputerName, Title, InstalledOn, ServiceID, FirstSeenRunId, LastSeenRunId)
    VALUES (s.ComputerName, s.Title, s.InstalledOn, s.ServiceID, s.RunId, s.RunId);
"@
        $SqlCommand.ExecuteNonQuery() | Out-Null

        # Sweep per (Computer, RunId) in batch: anything we didn't touch in
        # this run is gone.
        $SqlCommand.CommandText = @"
UPDATE iu
SET    UninstalledAt = SYSUTCDATETIME()
FROM   dbo.InstalledUpdates iu
INNER JOIN (SELECT DISTINCT ComputerName, RunId FROM #StageIU) b
        ON b.ComputerName = iu.ComputerName
WHERE  iu.LastSeenRunId <> b.RunId
  AND  iu.UninstalledAt IS NULL;
"@
        $swept = $SqlCommand.ExecuteNonQuery()

        $SqlCommand.CommandText = 'DROP TABLE #StageIU'
        $SqlCommand.ExecuteNonQuery() | Out-Null

        Write-Host ("InstalledUpdates bulk: staged {0:N0} rows, swept {1:N0}" -f $rowCount, $swept)
    }
    catch {
        $script:hasErrors = $true
        "Error bulk-merging InstalledUpdates : $($_.Exception.Message)" | Out-File -FilePath $logFilePath -Append
        Write-Error "Error bulk-merging InstalledUpdates : $_"
    }
    finally {
        $SqlConnection.Dispose()
    }
}

# Bulk-load a snapshot fact table. Stages rows in a #temp table via
# SqlBulkCopy, then INSERT...SELECT WHERE NOT EXISTS into the target so
# same-RunId re-runs stay idempotent. Two SQL round-trips per table instead
# of one per row.
function Import-SnapshotTableBulk {
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)]$JsonContent
    )

    if (-not $JsonContent) { return }
    if (-not ($JsonContent -is [System.Array])) { $JsonContent = @($JsonContent) }
    if ($JsonContent.Count -eq 0) { return }

    $NaturalKey = Get-NaturalKey -TableName $TableName

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()
        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandTimeout = 600

        # Discover target column shape: skip IDENTITY (Id) and defaulted columns
        # (CreatedAt) so the staging table + bulk copy line up cleanly.
        $SqlCommand.CommandText = @"
SELECT c.name AS ColumnName, t.name AS TypeName
FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(@tbl)
  AND c.is_identity = 0
  AND c.default_object_id = 0
ORDER BY c.column_id
"@
        $SqlCommand.Parameters.AddWithValue('@tbl', "dbo.$TableName") | Out-Null
        $providedCols = @()
        $reader = $SqlCommand.ExecuteReader()
        while ($reader.Read()) {
            $providedCols += [PSCustomObject]@{
                Name = [string]$reader['ColumnName']
                Type = [string]$reader['TypeName']
            }
        }
        $reader.Close()
        $SqlCommand.Parameters.Clear()
        if ($providedCols.Count -eq 0) {
            throw "No insertable columns discovered for [$TableName]"
        }

        # Build DataTable with .NET types matching the SQL column types
        $dt = New-Object System.Data.DataTable
        foreach ($col in $providedCols) {
            $netType = switch ($col.Type) {
                'bigint'           { [Int64] }
                'int'              { [Int32] }
                'smallint'         { [Int16] }
                'bit'              { [Boolean] }
                'uniqueidentifier' { [Guid] }
                'datetime2'        { [DateTime] }
                'datetime'         { [DateTime] }
                'date'             { [DateTime] }
                'decimal'          { [Decimal] }
                'numeric'          { [Decimal] }
                'float'            { [Double] }
                default            { [String] }
            }
            $dc = New-Object System.Data.DataColumn($col.Name, $netType)
            $dc.AllowDBNull = $true
            $dt.Columns.Add($dc) | Out-Null
        }

        # Materialise rows
        $rowsAdded = 0
        foreach ($Item in $JsonContent) {
            if ($null -eq $Item) { continue }
            $row = $dt.NewRow()
            foreach ($col in $providedCols) {
                $raw = if ($Item.PSObject.Properties.Name -contains $col.Name) { $Item.$($col.Name) } else { $null }
                $val = Convert-ToSimpleFormat $raw
                if ($null -eq $val) {
                    $row[$col.Name] = [DBNull]::Value
                    continue
                }
                try {
                    switch ($col.Type) {
                        'uniqueidentifier' { $row[$col.Name] = [Guid]::Parse([string]$val) }
                        'bigint'           { $row[$col.Name] = [Int64]$val }
                        'int'              { $row[$col.Name] = [Int32]$val }
                        'smallint'         { $row[$col.Name] = [Int16]$val }
                        'bit'              { $row[$col.Name] = [Boolean]$val }
                        'datetime2'        { $row[$col.Name] = [DateTime]$val }
                        'datetime'         { $row[$col.Name] = [DateTime]$val }
                        'date'             { $row[$col.Name] = ([DateTime]$val).Date }
                        'decimal'          { $row[$col.Name] = [Decimal]$val }
                        'numeric'          { $row[$col.Name] = [Decimal]$val }
                        'float'            { $row[$col.Name] = [Double]$val }
                        default            { $row[$col.Name] = [string]$val }
                    }
                } catch {
                    $row[$col.Name] = [DBNull]::Value
                }
            }
            $dt.Rows.Add($row)
            $rowsAdded++
        }
        if ($rowsAdded -eq 0) { return }

        # Stage in a temp table, then dedupe into target via NOT EXISTS.
        # Quoted column list reused everywhere.
        $colList = ($providedCols | ForEach-Object { "[$($_.Name)]" }) -join ', '
        $stageName = "#Stage_$TableName"

        $SqlCommand.CommandText = "SELECT TOP 0 $colList INTO [$stageName] FROM [$TableName]"
        $SqlCommand.ExecuteNonQuery() | Out-Null

        $bulk = New-Object System.Data.SqlClient.SqlBulkCopy($SqlConnection)
        try {
            $bulk.DestinationTableName = $stageName
            $bulk.BatchSize            = 5000
            $bulk.BulkCopyTimeout      = 600
            foreach ($col in $providedCols) {
                $bulk.ColumnMappings.Add($col.Name, $col.Name) | Out-Null
            }
            $bulk.WriteToServer($dt)
        } finally {
            $bulk.Close()
        }

        # NULL-safe equality: SQL `NULL = NULL` is UNKNOWN, so a plain `=` here
        # would let any row whose key column is NULL slip past the dedup check
        # on re-run. Treat (NULL, NULL) as a match.
        $joinPredicate = ($NaturalKey | ForEach-Object { "(t.[$_] = s.[$_] OR (t.[$_] IS NULL AND s.[$_] IS NULL))" }) -join ' AND '
        # Dedup WITHIN staging too: customer JSON occasionally has duplicate
        # natural keys (same software listed twice on one server, etc.). Take
        # the first row per key via ROW_NUMBER(); otherwise the UNIQUE index
        # would reject the whole batch.
        $partitionCols = ($NaturalKey | ForEach-Object { "[$_]" }) -join ', '
        $SqlCommand.CommandText = @"
WITH dedup AS (
    SELECT $colList,
           ROW_NUMBER() OVER (PARTITION BY $partitionCols ORDER BY (SELECT NULL)) AS rn
    FROM [$stageName]
)
INSERT INTO [$TableName] ($colList)
SELECT $colList
FROM dedup s
WHERE rn = 1
  AND NOT EXISTS (SELECT 1 FROM [$TableName] t WHERE $joinPredicate);

DROP TABLE [$stageName];
"@
        $inserted = $SqlCommand.ExecuteNonQuery()
        $skipped  = $rowsAdded - $inserted
        Write-Host ("Table {0}: bulk-inserted {1} rows (staged {2}, deduped {3})" -f $TableName, $inserted, $rowsAdded, $skipped)
    } catch {
        $script:hasErrors = $true
        "Error bulk-loading $TableName : $($_.Exception.Message)" | Out-File -FilePath $logFilePath -Append
        Write-Error "Error bulk-loading $TableName : $_"
    } finally {
        $SqlConnection.Dispose()
    }
}

function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)
        Test-SqlIdentifier -Name $TableName -Context "table name"

        # InstalledUpdates uses the differential model + a C# JSON loader that
        # streams the file directly into a DataTable.
        if ($TableName -eq 'InstalledUpdates') {
            Import-InstalledUpdatesDifferential -JsonFilePath $JsonFilePath
            return
        }

        $JsonContent = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        Import-SnapshotTableBulk -TableName $TableName -JsonContent $JsonContent
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred: $_"
    }
}

# Ingest CollectionRuns + Computers metadata FIRST so the FK targets are in
# place before any fact rows reference them. The file is required when fact
# rows carry RunIds - if it is missing the FK insert below fails fast.
$collectionRunsPath = Join-Path -Path $JsonFilesPath -ChildPath 'CollectionRuns.json'
if (Test-Path $collectionRunsPath) {
    Import-CollectionRunsJson -JsonFilePath $collectionRunsPath
}

# Iterate over each JSON file and update the corresponding table.
# CollectionRuns.json is handled above; skip it here so it doesn't get fed
# through the generic table loader.
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -ne 'CollectionRuns'
} | ForEach-Object {
    Write-Output ((Get-Date).ToString() + " Updating table from file: " + $($_.FullName))
    ((Get-Date).ToString() + " Updating table from file: " + $($_.FullName)) | Out-File -FilePath $logFilePath -Append
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}

if ($script:hasErrors) { exit 1 } else { exit 0 }
