#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:ScriptPath = Resolve-Path "$PSScriptRoot/../New-BicepReadme.ps1"
    . $script:ScriptPath

    function New-TestBicep {
        param([string]$Path)
        @"
metadata name = 'sample-module'
metadata description = 'Sample description.'

@description('Custom type description')
type customType = {
  @description('Setting name')
  settingName: string
  @description('Setting count')
  settingCount: int
}

@description('Positive int alias')
type positiveInt = int

@description('Resource name')
param name string

@description('Resource location')
param location string = resourceGroup().location

@description('Tag set')
param tags object = {
  Environment: 'dev'
  ManagedBy: 'bicep-docs'
}

@description('Custom type parameter')
param customTypeParam customType

@description('Nullable parameter')
param nullableParam string?

@description('Secure parameter')
@secure()
param secureValue string

@description('Variable description from source parser')
var computedName = 'demo'

@description('Storage account resource')
resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'examplestorage'
  location: resourceGroup().location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

@description('Resource id output')
output resourceId string = stg.id

@description('Custom output')
output customOutput positiveInt = 42
"@ | Set-Content -Path $Path -NoNewline
    }
}

Describe 'New-BicepReadme.ps1' {

    BeforeEach {
        $script:TempDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:TempDir | Out-Null

        $script:BicepFile = Join-Path $script:TempDir 'main.bicep'
        $script:OutFile = Join-Path $script:TempDir 'README.md'

        New-TestBicep -Path $script:BicepFile
    }

    Context 'Generation workflow' {

        It 'builds from bicep and writes a markdown file' {
            New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile | Out-Null

            Test-Path $script:OutFile | Should -BeTrue
        }
    }

    Context 'Formatting output' {

        It 'renders usage values as types rather than defaults' {
            New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile | Out-Null
            $actual = (Get-Content -Path $script:OutFile -Raw) -replace "`r`n", "`n"

            $actual | Should -Match 'customTypeParam: customType'
            $actual | Should -Match 'nullableParam: string\?'
            $actual | Should -Not -Match 'nullableParam: null'
            $actual | Should -Not -Match 'tags:\s*\{'
        }

        It 'links UDDT parameter types to the UDDT section anchor' {
            New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile | Out-Null
            $actual = (Get-Content -Path $script:OutFile -Raw) -replace "`r`n", "`n"

            $actual | Should -Match '\[customType \(uddt\)\]\(#customtype\)'
        }

        It 'renders expected section headers and key type formatting' {
            New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile | Out-Null
            $actual = (Get-Content -Path $script:OutFile -Raw) -replace "`r`n", "`n"

            $actual | Should -Match '\| Name \| Status \| Type \| Description \| Default \|'
            $actual | Should -Match 'string \(secure\)'
            $actual | Should -Match 'positiveInt \(uddt\)'
        }
    }

    Context 'Section filtering' {

        It 'supports include sections preserving order' {
            New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile -IncludeSections 'outputs,parameters' | Out-Null
            $actual = (Get-Content -Path $script:OutFile -Raw) -replace "`r`n", "`n"

            $outputsIndex = $actual.IndexOf('## Outputs')
            $paramsIndex = $actual.IndexOf('## Parameters')

            $outputsIndex | Should -BeGreaterThan -1
            $paramsIndex | Should -BeGreaterThan -1
            $outputsIndex | Should -BeLessThan $paramsIndex
        }

        It 'supports exclude sections from the default set' {
            New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile -ExcludeSections 'description,usage' | Out-Null
            $actual = (Get-Content -Path $script:OutFile -Raw) -replace "`r`n", "`n"

            $actual.Contains('## Description') | Should -BeFalse
            $actual.Contains('## Usage') | Should -BeFalse
            $actual.Contains('## Parameters') | Should -BeTrue
        }

        It 'rejects invalid sections' {
            {
                New-BicepReadme -InputPath $script:BicepFile -OutputPath $script:OutFile -IncludeSections 'parameters,badsection' | Out-Null
            } | Should -Throw '*Invalid section: badsection*'
        }
    }
}
