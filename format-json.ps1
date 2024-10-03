param (
    [string]$Path = ".",
    [switch]$Fix = $false
)

function Format-Json {
    Param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Json,
        [ValidateRange(1, 1024)]
        [int]$Indentation = 4
    )

    # If the input JSON text has been created with ConvertTo-Json -Compress
    # then we first need to reconvert it without compression
    if ($Json -notmatch '\r?\n') {
        $Json = ($Json | ConvertFrom-Json) | ConvertTo-Json -Depth 100
    }

    $indent = 0
    $regexUnlessQuoted = '(?=([^"]*"[^"]*")*[^"]*$)'

    $result = $Json -split '\r?\n' |
    ForEach-Object {
        # If the line contains a ] or } character, 
        # we need to decrement the indentation level, unless:
        #   - it is inside quotes, AND
        #   - it does not contain a [ or {
        if (($_ -match "[}\]]$regexUnlessQuoted") -and ($_ -notmatch "[\{\[]$regexUnlessQuoted")) {
            $indent = [Math]::Max($indent - $Indentation, 0)
        }

        # Replace all colon-space combinations by ": " unless it is inside quotes.
        $line = (' ' * $indent) + ($_.TrimStart() -replace ":\s+$regexUnlessQuoted", ': ')

        # If the line contains a [ or { character, 
        # we need to increment the indentation level, unless:
        #   - it is inside quotes, AND
        #   - it does not contain a ] or }
        if (($_ -match "[\{\[]$regexUnlessQuoted") -and ($_ -notmatch "[}\]]$regexUnlessQuoted")) {
            $indent += $Indentation
        }

        # Powershell 5.10 doesn't handle some chars well
        # Replace escapped "\u0027" with "'"
        # Replace escapped "\u0026" with "&"
        $line = $line -replace "\\u0027", "'"
        $line = $line -replace "\\u0026", "&"

        $line
    }

    $res = ($result -Join [Environment]::NewLine)

    return $res
}

function Compare-Json {
    param (
        [System.Collections.Specialized.OrderedDictionary]$Base,
        [System.Collections.Specialized.OrderedDictionary]$Translation
    )
    $missingKeys = @()
    $superfluousKeys = @()

    foreach ($key in $Base.Keys) {
        if (-not $Translation.Contains($key)) {
            $missingKeys += $key
        }
    }

    foreach ($key in $Translation.Keys) {
        if (-not $Base.Contains($key)) {
            $superfluousKeys += $key
        }
    }

    return [pscustomobject]@{
        MissingKeys     = $missingKeys
        SuperfluousKeys = $superfluousKeys
    }
}

function ConvertTo-OrderedDictionary { 
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [pscustomobject]$object
    )
    $ordered = [ordered]@{}

    foreach ($property in $object.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }

    return $ordered
}

function ConvertTo-OrderedDictionaryFromArray { 
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object[]]$object
    )
    $ordered = [ordered]@{}

    foreach ($item in $object) {
        $ordered[$item.Name] = $item.Value
    }

    return $ordered
}


$fullPath = $Path | Resolve-Path
Write-Output "Scanning $fullPath"
Write-Output ""

$baseFiles = Get-ChildItem -Path $Path -Filter "*.json" -Recurse | Where-Object { $_.Name -notmatch "\.[a-z]{2}(-[a-z]{2})?\.json$" }

$exitCode = 0

foreach ($baseFile in $baseFiles) {
    $baseJson = Get-Content -Path $baseFile.FullName -Raw;
    $baseDictionary = $baseJson | ConvertFrom-Json | ConvertTo-OrderedDictionary
    $translationFiles = $translationFiles = Get-ChildItem -Path $baseFile.DirectoryName -Filter "$($baseFile.BaseName).*.json"

    foreach ($translationFile in $translationFiles) {
        $translationJson = Get-Content -Path $translationFile.FullName -Raw
        $translation = $translationJson  | ConvertFrom-Json | ConvertTo-OrderedDictionary
        $comparison = Compare-Json -Base $baseDictionary -Translation $translation

        if ($comparison.MissingKeys.Count -gt 0 -or $comparison.SuperfluousKeys.Count -gt 0) {
            $exitCode = -1
            Write-Output "File: $($translationFile.FullName)"
            Write-Output "Missing Keys: $($comparison.MissingKeys -join ', ')"
            Write-Output "Superfluous Keys: $($comparison.SuperfluousKeys -join ', ')"

            if ($Fix) {
                foreach ($key in $comparison.MissingKeys) {
                    $translation[$key] = $baseDictionary[$key]
                }

                foreach ($key in $comparison.SuperfluousKeys) {
                    $translation.Remove($key)
                }
                
                $formattedJson = ConvertTo-OrderedDictionaryFromArray($translation.GetEnumerator() | Sort-Object -Property Name ) | ConvertTo-Json -Depth 100 | Format-Json -Indentation 2

                if ($formattedJson -ne $translationJson) {
                    Write-Output "Fixing translationFile"
                    Set-Content -Path $translationFile.FullName -Value $formattedJson -NoNewLine
                }
            }
        }
        else {
            $formattedTranslationJson = ConvertTo-OrderedDictionaryFromArray($translation.GetEnumerator() | Sort-Object -Property Name) | ConvertTo-Json -Depth 100 | Format-Json -Indentation 2
            if ($formattedTranslationJson -ne $translationJson) {
                $exitCode = -1
                if ($Fix) {
                    Write-Output "Formatting $translationFile"
                    Set-Content -Path $translationFile.FullName -Value $formattedTranslationJson -NoNewLine
                }
            }
        }
    }

    $formattedBaseJson = ConvertTo-OrderedDictionaryFromArray( $baseDictionary.GetEnumerator() | Sort-Object -Property Name) | ConvertTo-Json -Depth 100 | Format-Json -Indentation 2
    if ($formattedBaseJson -ne $baseJson) {
        $exitCode = -1;
        if ($Fix) {
            Write-Output "Formatting $baseFile"
            Set-Content -Path $baseFile.FullName -Value $formattedBaseJson -NoNewLine
        }
    }
    
}

if ($exitCode -eq 0) {
    Write-Output "No problem found!"
}
else {
    Write-Output ""
    Write-Output "Problems found!"
}

exit $exitCode