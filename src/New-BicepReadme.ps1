[CmdletBinding()]
param(
    [Parameter()]
    [string]$InputPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$IncludeSections,

    [Parameter()]
    [string]$ExcludeSections,

    [Parameter()]
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultSections = @('description', 'usage', 'modules', 'resources', 'parameters', 'uddts', 'udfs', 'variables', 'outputs')

function Get-SectionList {
    param(
        [string]$Include,
        [string]$Exclude
    )

    if (-not [string]::IsNullOrWhiteSpace($Include) -and -not [string]::IsNullOrWhiteSpace($Exclude)) {
        $normalizedInclude = (($Include -split ',').ForEach({ $_.Trim().ToLowerInvariant() }) | Where-Object { $_ -ne '' })
        $matchesDefault = ($normalizedInclude.Count -eq $DefaultSections.Count) -and -not (Compare-Object -ReferenceObject $normalizedInclude -DifferenceObject $DefaultSections)
        if (-not $matchesDefault) {
            throw "Both IncludeSections and ExcludeSections cannot be used together unless IncludeSections exactly matches the default section order."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Include)) {
        $sections = ($Include -split ',').ForEach({ $_.Trim().ToLowerInvariant() }) | Where-Object { $_ -ne '' }
        foreach ($section in $sections) {
            if ($DefaultSections -notcontains $section) {
                throw "Invalid section: $section"
            }
        }
        return , $sections
    }

    if (-not [string]::IsNullOrWhiteSpace($Exclude)) {
        $excludeSet = @{}
        ($Exclude -split ',').ForEach({ $_.Trim().ToLowerInvariant() }) | Where-Object { $_ -ne '' } | ForEach-Object {
            if ($DefaultSections -notcontains $_) {
                throw "Invalid section: $_"
            }
            $excludeSet[$_] = $true
        }

        $final = @()
        foreach ($section in $DefaultSections) {
            if (-not $excludeSet.ContainsKey($section)) {
                $final += $section
            }
        }
        return , $final
    }

    return , $DefaultSections
}

function Test-CommandExists {
    param([string]$Name)

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BicepFilePath
    )

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($BicepFilePath)
    $outFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("{0}_{1}.json" -f $fileName, [guid]::NewGuid().ToString())

    if (Test-CommandExists -Name 'bicep') {
        & bicep build $BicepFilePath --outfile $outFile | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build Bicep template using bicep CLI."
        }
        return $outFile
    }

    if (Test-CommandExists -Name 'az') {
        & az bicep build --file $BicepFilePath --outfile $outFile | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build Bicep template using Azure CLI."
        }
        return $outFile
    }

    throw "Neither 'bicep' nor 'az' command was found in PATH."
}

function Get-JsonPropertyValue {
    param(
        [Parameter()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function ConvertTo-PropertyList {
    param([object]$Object)

    if ($null -eq $Object) {
        return @()
    }

    $list = @()
    foreach ($property in $Object.PSObject.Properties) {
        $list += [pscustomobject]@{
            Name  = $property.Name
            Value = $property.Value
        }
    }
    return $list
}

function Format-DescriptionText {
    param([string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $description = $Text -replace "`r`n", '<br>'
    $description = $description -replace "`n", '<br>'
    return $description
}

function Format-DefaultValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $json = $Value | ConvertTo-Json -Compress -Depth 100
    $json = $json -replace '":', '": '
    $json = $json -replace ',"', ', "'
    $json = $json -replace "`r`n", '<br>'
    $json = $json -replace "`n", '<br>'
    return $json
}

function Get-DisplayType {
    param(
        [string]$Type,
        [object]$Items
    )

    $lower = $Type.ToLowerInvariant()
    if ($lower -eq 'securestring') {
        return 'string (secure)'
    }
    if ($lower -eq 'secureobject') {
        return 'object (secure)'
    }

    if ($Type.StartsWith('#/definitions/')) {
        $split = $Type -split '/'
        return "{0} (uddt)" -f $split[$split.Length - 1]
    }

    if ($Type -eq 'array' -and $null -ne $Items) {
        $itemType = Get-JsonPropertyValue -Object $Items -PropertyName 'type'
        if ($null -ne $itemType) {
            return "$itemType[]"
        }

        $itemRef = Get-JsonPropertyValue -Object $Items -PropertyName '$ref'
        if ($null -ne $itemRef) {
            if ($itemRef.StartsWith('#/definitions/')) {
                $split = $itemRef -split '/'
                return "{0}[] (uddt)" -f $split[$split.Length - 1]
            }
            return "$itemRef[]"
        }
    }

    return $Type
}

function New-MarkdownTable {
    param(
        [string]$Title,
        [string[]]$Headers,
        [object[]]$Rows
    )

    if ($Headers.Count -eq 0) {
        return ''
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("## $Title")
    [void]$builder.AppendLine('')

    [void]$builder.Append('| ')
    [void]$builder.Append(($Headers -join ' | '))
    [void]$builder.AppendLine(' |')

    [void]$builder.Append('| ')
    [void]$builder.Append((@('---') * $Headers.Count -join ' | '))
    [void]$builder.AppendLine(' |')

    foreach ($row in $Rows) {
        [void]$builder.Append('| ')
        [void]$builder.Append(($row -join ' | '))
        [void]$builder.AppendLine(' |')
    }

    return $builder.ToString().TrimEnd("`r", "`n")
}

function Get-BicepSourceInfo {
    param([string]$BicepFilePath)

    $content = Get-Content -Path $BicepFilePath -Raw
    $lines = $content -split "`r?`n"

    $moduleRegex = [regex]'^module\s+(\S+)\s+''(\S+)'''
    $resourceRegex = [regex]'^resource\s+(\S+)\s+''(\S+)'''
    $variableRegex = [regex]'^var\s+(\S+)\s+'
    $typeRegex = [regex]'^type\s+(\S+)\s+'
    $outputRegex = [regex]'^output\s+(\S+)\s+'
    $parameterRegex = [regex]'^param\s+(\S+)\s+'
    $inlineDescriptionRegex = [regex]"^@(description|sys\.description)\(('''|')(.*?)('''|')\)"
    $multilineDescriptionStartRegex = [regex]"^@(description|sys\.description)\('''(.*)"

    $modules = @()
    $resources = @()
    $variables = @()
    $variableDescriptions = @{}

    $inMultilineComment = $false
    $currentDescription = ''

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()

        if ($trimmed -eq '') {
            continue
        }

        if ($inMultilineComment) {
            if ($trimmed.Contains('*/')) {
                $inMultilineComment = $false
            }
            continue
        }

        if ($trimmed.StartsWith('//')) {
            continue
        }

        if ($trimmed.StartsWith('/*')) {
            if (-not $trimmed.Contains('*/')) {
                $inMultilineComment = $true
            }
            continue
        }

        $inlineMatch = $inlineDescriptionRegex.Match($trimmed)
        if ($inlineMatch.Success) {
            $currentDescription = $inlineMatch.Groups[3].Value
            continue
        }

        $multilineStartMatch = $multilineDescriptionStartRegex.Match($trimmed)
        if ($multilineStartMatch.Success) {
            $descBuilder = New-Object System.Text.StringBuilder
            [void]$descBuilder.Append($multilineStartMatch.Groups[2].Value)

            if ($trimmed.EndsWith("''')")) {
                $text = $descBuilder.ToString()
                $text = $text.Substring(0, $text.Length - 3)
                $currentDescription = $text
                continue
            }

            while (($i + 1) -lt $lines.Length) {
                $i++
                $next = $lines[$i]
                if ($next.EndsWith("''')")) {
                    [void]$descBuilder.Append("`n")
                    [void]$descBuilder.Append($next.Substring(0, $next.Length - 4))
                    break
                }

                [void]$descBuilder.Append("`n")
                [void]$descBuilder.Append($next)
            }

            $currentDescription = $descBuilder.ToString()
            continue
        }

        if ($typeRegex.IsMatch($trimmed) -or $outputRegex.IsMatch($trimmed) -or $parameterRegex.IsMatch($trimmed)) {
            $currentDescription = ''
            continue
        }

        $moduleMatch = $moduleRegex.Match($trimmed)
        if ($moduleMatch.Success) {
            $modules += [pscustomobject]@{
                SymbolicName = $moduleMatch.Groups[1].Value
                Source       = $moduleMatch.Groups[2].Value
                Description  = $currentDescription
            }
            $currentDescription = ''
            continue
        }

        $resourceMatch = $resourceRegex.Match($trimmed)
        if ($resourceMatch.Success) {
            $resourceType = $resourceMatch.Groups[2].Value.Split('@')[0]
            $resources += [pscustomobject]@{
                SymbolicName = $resourceMatch.Groups[1].Value
                Type         = $resourceType
                Description  = $currentDescription
            }
            $currentDescription = ''
            continue
        }

        $variableMatch = $variableRegex.Match($trimmed)
        if ($variableMatch.Success) {
            $varName = $variableMatch.Groups[1].Value
            $variables += $varName
            $variableDescriptions[$varName] = $currentDescription
            $currentDescription = ''
            continue
        }
    }

    $modules = $modules | Sort-Object -Property SymbolicName
    $resources = $resources | Sort-Object -Property SymbolicName

    return [pscustomobject]@{
        Modules              = @($modules)
        Resources            = @($resources)
        VariableDescriptions = $variableDescriptions
    }
}

function Get-TemplateName {
    param(
        [object]$Template,
        [string]$BicepFilePath
    )

    $metadata = Get-JsonPropertyValue -Object $Template -PropertyName 'metadata'
    $name = Get-JsonPropertyValue -Object $metadata -PropertyName 'name'
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return $name
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($BicepFilePath)
}

function Get-TemplateDescription {
    param([object]$Template)

    $metadata = Get-JsonPropertyValue -Object $Template -PropertyName 'metadata'
    $description = Get-JsonPropertyValue -Object $metadata -PropertyName 'description'
    if ($null -eq $description) {
        return ''
    }

    return [string]$description
}

function Get-Parameters {
    param([object]$Template)

    $parametersObj = Get-JsonPropertyValue -Object $Template -PropertyName 'parameters'
    $parameterProps = ConvertTo-PropertyList -Object $parametersObj | Sort-Object -Property Name

    $result = @()
    foreach ($property in $parameterProps) {
        $name = $property.Name
        $value = $property.Value

        $type = Get-JsonPropertyValue -Object $value -PropertyName 'type'
        $refType = Get-JsonPropertyValue -Object $value -PropertyName '$ref'
        if ([string]::IsNullOrWhiteSpace($type)) {
            if (-not [string]::IsNullOrWhiteSpace($refType)) {
                $type = $refType
            }
            else {
                $type = 'any'
            }
        }

        $items = Get-JsonPropertyValue -Object $value -PropertyName 'items'
        $defaultValue = Get-JsonPropertyValue -Object $value -PropertyName 'defaultValue'
        $nullable = [bool](Get-JsonPropertyValue -Object $value -PropertyName 'nullable')
        $metadata = Get-JsonPropertyValue -Object $value -PropertyName 'metadata'
        $description = Format-DescriptionText -Text ([string](Get-JsonPropertyValue -Object $metadata -PropertyName 'description'))

        $isRequired = ($null -eq $defaultValue) -and (-not $nullable)
        $status = if ($isRequired) { 'Required' } else { 'Optional' }

        $result += [pscustomobject]@{
            Name        = $name
            Status      = $status
            Type        = Get-DisplayType -Type $type -Items $items
            Description = $description
            Default     = if ($null -eq $defaultValue -and $nullable) { 'null' } else { Format-DefaultValue -Value $defaultValue }
            IsRequired  = $isRequired
            Nullable    = $nullable
            RawDefault  = $defaultValue
        }
    }

    return $result
}

function Get-Outputs {
    param([object]$Template)

    $outputsObj = Get-JsonPropertyValue -Object $Template -PropertyName 'outputs'
    $outputProps = ConvertTo-PropertyList -Object $outputsObj | Sort-Object -Property Name

    $result = @()
    foreach ($property in $outputProps) {
        $name = $property.Name
        $value = $property.Value

        $type = Get-JsonPropertyValue -Object $value -PropertyName 'type'
        $refType = Get-JsonPropertyValue -Object $value -PropertyName '$ref'
        if ([string]::IsNullOrWhiteSpace($type)) {
            if (-not [string]::IsNullOrWhiteSpace($refType)) {
                $type = $refType
            }
            else {
                $type = 'any'
            }
        }

        $items = Get-JsonPropertyValue -Object $value -PropertyName 'items'
        $metadata = Get-JsonPropertyValue -Object $value -PropertyName 'metadata'
        $description = Format-DescriptionText -Text ([string](Get-JsonPropertyValue -Object $metadata -PropertyName 'description'))

        $result += [pscustomobject]@{
            Name        = $name
            Type        = Get-DisplayType -Type $type -Items $items
            Description = $description
        }
    }

    return $result
}

function Get-Variables {
    param(
        [object]$Template,
        [hashtable]$Descriptions
    )

    $variablesObj = Get-JsonPropertyValue -Object $Template -PropertyName 'variables'
    if ($null -eq $variablesObj) {
        return @()
    }

    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($property in $variablesObj.PSObject.Properties) {
        if ($property.Name -eq 'copy') {
            foreach ($copyItem in $property.Value) {
                $copyName = Get-JsonPropertyValue -Object $copyItem -PropertyName 'name'
                if (-not [string]::IsNullOrWhiteSpace($copyName)) {
                    [void]$names.Add($copyName)
                }
            }
            continue
        }

        if ($property.Name.StartsWith('$fxv#')) {
            continue
        }

        [void]$names.Add($property.Name)
    }

    $result = @()
    foreach ($name in ($names | Sort-Object)) {
        $desc = ''
        if ($Descriptions.ContainsKey($name)) {
            $desc = $Descriptions[$name]
        }

        $result += [pscustomobject]@{
            Name        = $name
            Description = Format-DescriptionText -Text $desc
        }
    }

    return $result
}

function Get-UserDefinedDataTypes {
    param([object]$Template)

    $definitions = Get-JsonPropertyValue -Object $Template -PropertyName 'definitions'
    $definitionProps = ConvertTo-PropertyList -Object $definitions | Sort-Object -Property Name

    $result = @()
    foreach ($definition in $definitionProps) {
        $name = $definition.Name
        $value = $definition.Value

        $type = Get-JsonPropertyValue -Object $value -PropertyName 'type'
        $refType = Get-JsonPropertyValue -Object $value -PropertyName '$ref'
        if ([string]::IsNullOrWhiteSpace($type)) {
            if (-not [string]::IsNullOrWhiteSpace($refType)) {
                $type = $refType
            }
            else {
                $type = 'any'
            }
        }

        $items = Get-JsonPropertyValue -Object $value -PropertyName 'items'
        $metadata = Get-JsonPropertyValue -Object $value -PropertyName 'metadata'
        $description = Format-DescriptionText -Text ([string](Get-JsonPropertyValue -Object $metadata -PropertyName 'description'))

        $propertiesObj = Get-JsonPropertyValue -Object $value -PropertyName 'properties'
        $properties = @()
        foreach ($prop in (ConvertTo-PropertyList -Object $propertiesObj | Sort-Object -Property Name)) {
            $propertyValue = $prop.Value
            $propertyType = Get-JsonPropertyValue -Object $propertyValue -PropertyName 'type'
            $propertyRef = Get-JsonPropertyValue -Object $propertyValue -PropertyName '$ref'
            if ([string]::IsNullOrWhiteSpace($propertyType)) {
                if (-not [string]::IsNullOrWhiteSpace($propertyRef)) {
                    $propertyType = $propertyRef
                }
                else {
                    $propertyType = 'any'
                }
            }

            $propertyItems = Get-JsonPropertyValue -Object $propertyValue -PropertyName 'items'
            $propertyMetadata = Get-JsonPropertyValue -Object $propertyValue -PropertyName 'metadata'

            $properties += [pscustomobject]@{
                Name        = $prop.Name
                Type        = Get-DisplayType -Type $propertyType -Items $propertyItems
                Description = Format-DescriptionText -Text ([string](Get-JsonPropertyValue -Object $propertyMetadata -PropertyName 'description'))
            }
        }

        $result += [pscustomobject]@{
            Name        = $name
            Type        = Get-DisplayType -Type $type -Items $items
            Description = $description
            Properties  = @($properties)
        }
    }

    return $result
}

function Get-UserDefinedFunctions {
    param([object]$Template)

    $functions = Get-JsonPropertyValue -Object $Template -PropertyName 'functions'
    if ($null -eq $functions) {
        return @()
    }

    $result = @()
    foreach ($functionBlock in $functions) {
        $members = Get-JsonPropertyValue -Object $functionBlock -PropertyName 'members'
        foreach ($member in (ConvertTo-PropertyList -Object $members | Sort-Object -Property Name)) {
            $name = $member.Name
            $value = $member.Value

            $metadata = Get-JsonPropertyValue -Object $value -PropertyName 'metadata'
            $output = Get-JsonPropertyValue -Object $value -PropertyName 'output'
            $outputType = Get-JsonPropertyValue -Object $output -PropertyName 'type'
            $outputRef = Get-JsonPropertyValue -Object $output -PropertyName '$ref'
            if ([string]::IsNullOrWhiteSpace($outputType)) {
                if (-not [string]::IsNullOrWhiteSpace($outputRef)) {
                    $outputType = $outputRef
                }
                else {
                    $outputType = 'any'
                }
            }

            $outputItems = Get-JsonPropertyValue -Object $output -PropertyName 'items'

            $result += [pscustomobject]@{
                Name        = $name
                Description = Format-DescriptionText -Text ([string](Get-JsonPropertyValue -Object $metadata -PropertyName 'description'))
                OutputType  = Get-DisplayType -Type $outputType -Items $outputItems
            }
        }
    }

    return ($result | Sort-Object -Property Name)
}

function Get-UsageTypePlaceholder {
    param(
        [string]$DisplayType,
        [bool]$Nullable
    )

    if ([string]::IsNullOrWhiteSpace($DisplayType)) {
        return 'any'
    }

    $usageType = $DisplayType -replace ' \(uddt\)$', ''
    $usageType = $usageType -replace ' \(secure\)$', ''
    if ($Nullable -and -not $usageType.EndsWith('?')) {
        $usageType = "${usageType}?"
    }
    return $usageType
}

function Get-ParameterTypeMarkdown {
    param([string]$DisplayType)

    if ([string]::IsNullOrWhiteSpace($DisplayType)) {
        return ''
    }

    if ($DisplayType -match '^(?<name>.+?) \(uddt\)$') {
        $baseName = $Matches['name'] -replace '\[\]$', ''
        return "[{0}](#{1})" -f $DisplayType, $baseName.ToLowerInvariant()
    }

    return $DisplayType
}

function Get-UsageSection {
    param([object[]]$Parameters)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('## Usage')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Here is a basic example of how to use this Bicep module:')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('```bicep')
    [void]$builder.AppendLine("module symbolicName 'path_to_module | container_registry_reference' = {")
    [void]$builder.AppendLine('  params: {')
    [void]$builder.AppendLine('    // Required parameters')

    foreach ($parameter in $Parameters) {
        if ($null -eq $parameter -or $null -eq $parameter.PSObject.Properties['IsRequired']) {
            continue
        }
        if ($parameter.IsRequired) {
            $usageType = Get-UsageTypePlaceholder -DisplayType $parameter.Type -Nullable ([bool]$parameter.Nullable)
            [void]$builder.AppendLine("    $($parameter.Name): $usageType")
        }
    }

    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('    // Optional parameters')
    foreach ($parameter in $Parameters) {
        if ($null -eq $parameter -or $null -eq $parameter.PSObject.Properties['IsRequired']) {
            continue
        }
        if ($parameter.IsRequired) {
            continue
        }

        $usageType = Get-UsageTypePlaceholder -DisplayType $parameter.Type -Nullable ([bool]$parameter.Nullable)
        [void]$builder.AppendLine("    $($parameter.Name): $usageType")
    }

    [void]$builder.AppendLine('  }')
    [void]$builder.AppendLine('}')
    [void]$builder.AppendLine('```')

    return $builder.ToString().TrimEnd("`r", "`n")
}

function New-BicepDocsMarkdown {
    param(
        [string]$BicepFilePath,
        [object]$Template,
        [object]$SourceInfo,
        [string[]]$Sections
    )

    $title = Get-TemplateName -Template $Template -BicepFilePath $BicepFilePath
    $description = Get-TemplateDescription -Template $Template
    $modules = @($SourceInfo.Modules)
    $resources = @($SourceInfo.Resources)
    $parameters = @(Get-Parameters -Template $Template)
    $outputs = @(Get-Outputs -Template $Template)
    $variables = @(Get-Variables -Template $Template -Descriptions $SourceInfo.VariableDescriptions)
    $uddt = @(Get-UserDefinedDataTypes -Template $Template)
    $udf = @(Get-UserDefinedFunctions -Template $Template)

    $blocks = @()
    $blocks += "# $title"

    foreach ($section in $Sections) {
        switch ($section) {
            'description' {
                if (-not [string]::IsNullOrWhiteSpace($description)) {
                    $blocks += "## Description`n`n$description"
                }
            }
            'usage' {
                $blocks += (Get-UsageSection -Parameters $parameters)
            }
            'modules' {
                if ($modules.Count -gt 0) {
                    $rows = @()
                    foreach ($module in $modules) {
                        $rows += , @(
                            $module.SymbolicName,
                            $module.Source,
                            (Format-DescriptionText -Text $module.Description)
                        )
                    }
                    $blocks += (New-MarkdownTable -Title 'Modules' -Headers @('Symbolic Name', 'Source', 'Description') -Rows $rows)
                }
            }
            'resources' {
                if ($resources.Count -gt 0) {
                    $rows = @()
                    foreach ($resource in $resources) {
                        $typeLink = "[{0}](https://learn.microsoft.com/en-us/azure/templates/{1})" -f $resource.Type, $resource.Type.ToLowerInvariant()
                        $rows += , @(
                            $resource.SymbolicName,
                            $typeLink,
                            (Format-DescriptionText -Text $resource.Description)
                        )
                    }
                    $blocks += (New-MarkdownTable -Title 'Resources' -Headers @('Symbolic Name', 'Type', 'Description') -Rows $rows)
                }
            }
            'parameters' {
                if ($parameters.Count -gt 0) {
                    $rows = @()
                    foreach ($parameter in $parameters) {
                        $parameterType = Get-ParameterTypeMarkdown -DisplayType $parameter.Type
                        $rows += , @(
                            $parameter.Name,
                            $parameter.Status,
                            $parameterType,
                            $parameter.Description,
                            $parameter.Default
                        )
                    }
                    $blocks += (New-MarkdownTable -Title 'Parameters' -Headers @('Name', 'Status', 'Type', 'Description', 'Default') -Rows $rows)
                }
            }
            'uddts' {
                if ($uddt.Count -gt 0) {
                    $rows = @()
                    foreach ($dataType in $uddt) {
                        $properties = @($dataType.Properties)
                        $propertiesLink = if ($properties.Count -gt 0) { "[View Properties](#{0})" -f $dataType.Name.ToLowerInvariant() } else { '' }
                        $rows += , @(
                            $dataType.Name,
                            $dataType.Type,
                            $dataType.Description,
                            $propertiesLink
                        )
                    }
                    $table = New-MarkdownTable -Title 'User Defined Data Types (UDDTs)' -Headers @('Name', 'Type', 'Description', 'Properties') -Rows $rows

                    $subTables = @()
                    foreach ($dataType in $uddt) {
                        $properties = @($dataType.Properties)
                        if ($properties.Count -eq 0) {
                            continue
                        }

                        $propertyRows = @()
                        foreach ($prop in $properties) {
                            $propertyRows += , @($prop.Name, $prop.Type, $prop.Description)
                        }

                        $sub = New-Object System.Text.StringBuilder
                        [void]$sub.AppendLine("### $($dataType.Name)")
                        [void]$sub.AppendLine('')
                        [void]$sub.AppendLine((New-MarkdownTable -Title '' -Headers @('Name', 'Type', 'Description') -Rows $propertyRows).Replace('## ', '').TrimStart())
                        $subTables += $sub.ToString().TrimEnd("`r", "`n")
                    }

                    if ($subTables.Count -gt 0) {
                        $blocks += ($table + "`n`n" + ($subTables -join "`n`n"))
                    }
                    else {
                        $blocks += $table
                    }
                }
            }
            'udfs' {
                if ($udf.Count -gt 0) {
                    $rows = @()
                    foreach ($func in $udf) {
                        $rows += , @($func.Name, $func.Description, $func.OutputType)
                    }
                    $blocks += (New-MarkdownTable -Title 'User Defined Functions (UDFs)' -Headers @('Name', 'Description', 'Output Type') -Rows $rows)
                }
            }
            'variables' {
                if ($variables.Count -gt 0) {
                    $rows = @()
                    foreach ($variable in $variables) {
                        $rows += , @($variable.Name, $variable.Description)
                    }
                    $blocks += (New-MarkdownTable -Title 'Variables' -Headers @('Name', 'Description') -Rows $rows)
                }
            }
            'outputs' {
                if ($outputs.Count -gt 0) {
                    $rows = @()
                    foreach ($output in $outputs) {
                        $rows += , @($output.Name, $output.Type, $output.Description)
                    }
                    $blocks += (New-MarkdownTable -Title 'Outputs' -Headers @('Name', 'Type', 'Description') -Rows $rows)
                }
            }
            default {
                throw "Invalid section: $section"
            }
        }
    }

    return (($blocks -join "`n`n").TrimEnd("`r", "`n") + "`n")
}

function New-BicepReadme {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [string]$IncludeSections,

        [Parameter()]
        [string]$ExcludeSections,

        [Parameter()]
        [switch]$VerboseOutput
    )

    $resolvedInput = (Resolve-Path -Path $InputPath).Path
    if ([System.IO.Path]::GetExtension($resolvedInput).ToLowerInvariant() -ne '.bicep') {
        throw "InputPath must point to a .bicep file."
    }

    $resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path -Path (Split-Path -Path $resolvedInput -Parent) -ChildPath 'README.md'
    }
    else {
        if ([System.IO.Path]::IsPathRooted($OutputPath)) {
            $OutputPath
        }
        else {
            Join-Path -Path (Get-Location) -ChildPath $OutputPath
        }
    }

    $sections = Get-SectionList -Include $IncludeSections -Exclude $ExcludeSections
    $sourceInfo = Get-BicepSourceInfo -BicepFilePath $resolvedInput

    $tempFile = $null
    try {
        $tempFile = Invoke-BicepBuild -BicepFilePath $resolvedInput

        $template = Get-Content -Path $tempFile -Raw | ConvertFrom-Json -Depth 100
        $markdown = New-BicepDocsMarkdown -BicepFilePath $resolvedInput -Template $template -SourceInfo $sourceInfo -Sections $sections

        Set-Content -Path $resolvedOutput -Value $markdown -NoNewline
        if ($VerboseOutput) {
            Write-Host "Created/updated $resolvedOutput"
        }

        return $resolvedOutput
    }
    finally {
        if ($null -ne $tempFile -and (Test-Path -Path $tempFile)) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    New-BicepReadme -InputPath $InputPath -OutputPath $OutputPath -IncludeSections $IncludeSections -ExcludeSections $ExcludeSections -VerboseOutput:$VerboseOutput | Out-Null
}
