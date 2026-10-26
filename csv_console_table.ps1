<#
.SYNOPSIS
    Analyzes CSV files and creates a column type schema dynamically.
.DESCRIPTION
    Processes CSV files to identify column types and validates data against the schema.
    Print snapshot of data and schema in console table format.
.EXAMPLE
    ./csv_console_table.ps1 ./filename.csv
.NOTES
    Author: /* (c) 2025 G.E. Eidsness */
#>

[CmdletBinding()]
param(
    [string]$DefaultFile = "default.csv",
    [ValidateRange(1,1000)][int]$rowLimit = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Check if PowerShell version is 7.0 or higher
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This script requires PowerShell 7.0 or higher."
    exit 1
}

# Define column types enum
enum ColumnType {
    Null
    String 
    Int
    Float
    Double
    Bool
}

# Float keeps at most this many digits after the decimal point.
# More fractional digits, an exponent, or a trailing d/D suffix is Double.
$FloatDecimalPlaces = 2
$DoubleDecimalPlaces = 6

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

function Test-FloatLiteral {
    [CmdletBinding()]
    param(
        [string]$Value
    )
    return $Value -match "^\d+\.\d{1,$FloatDecimalPlaces}$"
}

# More than $FloatDecimalPlaces fractional digits, an exponent, or a trailing d/D suffix.
function Test-DoubleLiteral {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    $numeric = $Value
    $hasSuffix = $false
    if ($Value.Length -gt 1 -and $Value -cmatch '[dD]$') {
        $numeric = $Value.Substring(0, $Value.Length - 1)
        $hasSuffix = $true
    }

    if ($numeric -notmatch '^(?:\d+\.\d+|\d+)(?:[eE][+-]?\d+)?$') {
        return $false
    }
    if ($hasSuffix -or $numeric -match '[eE]') {
        return $true
    }

    $fraction = [regex]::Match($numeric, '^\d+\.(\d+)$')
    return $fraction.Success -and $fraction.Groups[1].Value.Length -gt $FloatDecimalPlaces
}

function Format-DoubleValue {
    [CmdletBinding()]
    param(
        [string]$Value
    )

    $numeric = $Value.Trim()
    if ($numeric.Length -gt 1 -and $numeric -cmatch '[dD]$') {
        $numeric = $numeric.Substring(0, $numeric.Length - 1)
    }

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $usesExponent = $numeric -match '[eE]'
    $number = [double]::Parse($numeric, $invariant)
    if (-not $usesExponent) {
        return $number.ToString("F$DoubleDecimalPlaces", $invariant)
    }

    # Match printf %e: at least two exponent digits (1.500000e-03), not the three .NET uses.
    $formatted = $number.ToString("e$DoubleDecimalPlaces", $invariant)
    if ($formatted -match '^(.*)e([+-])(\d+)$') {
        $exponent = [int]$Matches[3]
        return ('{0}e{1}{2:00}' -f $Matches[1], $Matches[2], $exponent)
    }
    return $formatted
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
        if (Test-DoubleLiteral $item) {
            $columnTypes += [ColumnType]::Double
        } elseif (Test-FloatLiteral $item) {
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
function ColorizeNull {
    [CmdletBinding()]
    param(
        [string]$value
    )
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
                    if (-not (Test-FloatLiteral $item)) {
                        $isValid = $false
                    }
                }
                "Double" {
                    if (-not (Test-DoubleLiteral $item)) {
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

function TruncateString {
    [CmdletBinding()]
    param(
        [string]$str,
        [int]$maxLength
    )
    if ($str.Length -gt $maxLength) {
        return $str.Substring(0, $maxLength) + "..."
    }
    return $str
}

# Main script section
try {
    # Same as csv_console_simple.ps1: the path is the parameter, including its default.
    if (-not ($DefaultFile -match '\.csv$')) {
        Write-Error "Input file must have a .csv extension"
        exit 4
    }

    if (-not (Test-Path -Path $DefaultFile)) {
        Write-Error "CSV file '$DefaultFile' does not exist."
        exit 2
    }

    try {
        $csvContent = Get-Content -Path $DefaultFile -ErrorAction Stop | Select-Object -First $rowLimit
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
            $columnIndex = 0
            $_.PSObject.Properties | ForEach-Object {
                $value = $_.Value
                if ($colTypes[$columnIndex] -eq [ColumnType]::Double) {
                    $value = Format-DoubleValue $value
                } elseif ($value -is [string]) {
                    $value = TruncateString $value 40
                }
                $newObject[$_.Name] = $value
                $columnIndex++
            }
            New-Object PSObject -Property $newObject
        }

        # Output $tableData to terminal | AND to file.txt
        $tableData | Format-Table -AutoSize | Tee-Object -FilePath "output.txt" -Encoding UTF8
    }

} catch {
    Write-Error -ErrorAction Continue $_.Exception.Message
    if ($_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage
    }
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace
    }
    exit 1
}
