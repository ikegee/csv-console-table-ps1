<#
.SYNOPSIS
    Analyzes CSV files and creates a column type schema dynamically.
.DESCRIPTION
    Processes CSV files to identify column types and validates data against the schema.
    Print snapshot of data and schema in console table format.
.EXAMPLE
    .\csv_console_table.ps1 .\filename.csv
.NOTES
    Author: G.E. Eidsness 
#>

[CmdletBinding()]
param(
    [string]$DefaultFile = "default.csv",
    [ValidateRange(1,1000)][int]$rowLimit = 10
)

# Define column types enum
enum ColumnType {
    Null
    String 
    Int
    Float
    Bool
}

# Function to get column types from a row
function Check-CSVRow-EmptyOrWhitespace {
    [CmdletBinding()]
    param (
        [string[]]$row
    )
    
    foreach ($column in $row) {
        # Trim leading and trailing whitespace
        $trimmedColumn = $column.Trim()        
        # Enhanced regex to match empty, whitespace-only fields, or null values (case insensitive)
        if ($trimmedColumn -match '^(?:["' + [char]39 + '])?\s*(?:["' + [char]39 + '])?$' -or 
            $trimmedColumn -imatch '^null$') {
            return $true
        }
    }
    return $false
}
# Updated function to validate data against schema
function Get-ColumnTypes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$row
    )
    
    # Check if the row contains any empty or whitespace-only values
    if (Check-CSVRow-EmptyOrWhitespace -row $row) {
        Write-Warning "Error: First row cannot contain empty or whitespace-only values to determine column types."
        exit 1
    }

    $columnTypes = @()
    foreach ($item in $row) {
        $item = $item.Trim()
        if ($item -imatch '^\d+\.\d+$') {
            $columnTypes += [ColumnType]::Float
        } elseif ($item -imatch '^\d+$') {
            $columnTypes += [ColumnType]::Int
        } elseif ($item -imatch '^(true|false)$') {
            $columnTypes += [ColumnType]::Bool
        } elseif ([string]::IsNullOrWhiteSpace($item) -or $item -imatch '^null$|^NULL$') {
            $columnTypes += [ColumnType]::Null
        } else {
            $columnTypes += [ColumnType]::String
        }
    }
    return $columnTypes
}

# Function to colorize null values (unused)
function ColorizeNull($value) {
    if ($value -imatch '^null$|^NULL$') {
        return "`e[31m$($value)`e[0m" # Red color
    }
    return $value
}

function Test-DataAgainstSchema {
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$rows,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [ColumnType[]]$schema
    )
    $validRows = @()
    $errors = $false
    foreach ($row in $rows) {
        $items = $row.Split(",")
        $isValid = $true
        
        if ($items.Count -ne $schema.Count) {
            Write-Warning "Row '$row' has invalid column count"
            $isValid = $false
            $errors = $true
            continue
        }
        
        for ($i = 0; $i -lt $items.Count; $i++) {
            $item = $items[$i].Trim()
            switch ($schema[$i]) {
                "Null" {
                    if (-not ([string]::IsNullOrWhiteSpace($item) -or $item -imatch '^null$|^NULL$')) {
                        $isValid = $false
                        $errors = $true
                        Write-Warning "Row '$row' expected Null in column $($i + 1) but found '$item'"
                        break
                    }
                }
                "Int" {
                    if (-not ($item -match '^\d+$')) {
                        $isValid = $false
                    }
                }
                "Float" {
                    if (-not ($item -match '^\d+\.\d+$')) {
                        $isValid = $false
                    }
                }
                "Bool" {
                    if (-not ($item -imatch '^(true|false)$')) {
                        $isValid = $false
                    }
                }
                "String" {
                    # Strings are accepted as-is
                }
            }
            if (-not $isValid) {
                Write-Warning "Row '$row' does not match schema at column $($i + 1)"
                $errors = $true
                break
            }
        }
        if ($isValid) {
            $validRows += $row
        }
    }
    return @{ ValidRows = $validRows; HasErrors = $errors }
}

function TruncateString($str, $maxLength) {
    if ($str.Length -gt $maxLength) {
        return $str.Substring(0, $maxLength) + "..."
    }
    return $str
}

# Main script section
try {
    $inputFile = ($args.Count -gt 0) ? $args[0] : $DefaultFile 
    
    # Add file existence check
    if (-not (Test-Path $inputFile)) {
        Write-Error "CSV file '$inputFile' does not exist."
        exit 2
    }
    
    try {
        $csvContent = Get-Content $inputFile -ErrorAction Stop | Select-Object -First $rowLimit
    } catch [System.IO.IOException] {
        Write-Error "File access error: $_"
        exit 3
    }
    # Check if the CSV file is empty
    if ($csvContent.Count -eq 0) {
        Write-Error "CSV file is empty."
        exit 1
    }

    # Remove empty lines
    $csvContent = $csvContent | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    
    $firstRow = $csvContent[0]
    $firstRowItems = $firstRow -split ','
    
    # Check for empty fields in the first row
    if (Check-CSVRow-EmptyOrWhitespace -row $firstRowItems) {
        Write-Warning "Error: First row cannot contain empty or whitespace-only values to determine column types."
        exit 1
    }
    
    $colTypes = Get-ColumnTypes $firstRowItems
    $colCount = $firstRowItems.Count

    # Create unique headers with suffixes for duplicates
    $headerCounts = @{}
    $dynHeaders = 1..$colCount | ForEach-Object {
        $type = $colTypes[$_-1]
        if ($headerCounts.ContainsKey($type)) {
            $headerCounts[$type] += 1
            "$type$($headerCounts[$type])"
        } else {
            $headerCounts[$type] = 1
            "$type"
        }
    }

    # Validate data rows against schema
    $validationResult = Test-DataAgainstSchema -rows $csvContent -schema $colTypes
    $validRows = $validationResult.ValidRows
    $hasErrors = $validationResult.HasErrors

    if ($hasErrors -or $validRows.Count -eq 0) {
        Write-Host "CSV data contains errors. Please check the warnings above."
        exit 0
    } else {
        # Convert valid data rows to CSV format with dynamic headers
        $csvString = $validRows -join "`n"
        $csv = $csvString | ConvertFrom-Csv -Header $dynHeaders

        # Process CSV content and store the result in $tableData
        $tableData = $csv | ForEach-Object {
            $newObject = [ordered]@{}
            $_.PSObject.Properties | ForEach-Object {
                $value = if ($_.Value -is [string]) { TruncateString $_.Value 40 } else { $_.Value }
                $newObject[$_.Name] = $value
            }
            New-Object PSObject -Property $newObject
        }

        # Output $tableData to terminal | AND to file.txt
        $tableData | Format-Table -AutoSize | Tee-Object -FilePath "output.txt" -Encoding UTF8
    }

} catch {
    Write-Error "Usage: $($MyInvocation.MyCommand.Name) <csv_file_path>"
    exit 1
}
