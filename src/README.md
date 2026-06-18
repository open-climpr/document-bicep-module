# New-BicepReadme

This utility generates a `README.md` from a `.bicep` file using only Bicep CLI or Azure CLI.

Script: `New-BicepReadme.ps1`

## Requirements

- PowerShell 7+
- One of the following available in `PATH`:
  - `bicep`
  - `az` (with `az bicep` support)

Build fallback order matches upstream behavior:

1. `bicep build`
2. `az bicep build`

## Basic Usage

Generate `README.md` in the same folder as the input Bicep file:

```powershell
pwsh -NoProfile -File ./util/bicep-docs/New-BicepReadme.ps1 \
  -InputPath <modulePath>/main.bicep
```

Generate to an explicit output path:

```powershell
pwsh -NoProfile -File ./util/bicep-docs/New-BicepReadme.ps1 \
  -InputPath <modulePath>/main.bicep \
  -OutputPath <modulePath>/README.generated.md
```

Enable verbose script output:

```powershell
pwsh -NoProfile -File ./util/bicep-docs/New-BicepReadme.ps1 \
  -InputPath <modulePath>/main.bicep \
  -VerboseOutput
```

## Section Controls

Default sections and order:

- `description,usage,modules,resources,parameters,uddts,udfs,variables,outputs`

Include only selected sections (order is respected):

```powershell
pwsh -NoProfile -File ./util/bicep-docs/New-BicepReadme.ps1 \
  -InputPath <modulePath>/main.bicep \
  -IncludeSections outputs,parameters
```

Exclude sections from the default set:

```powershell
pwsh -NoProfile -File ./util/bicep-docs/New-BicepReadme.ps1 \
  -InputPath <modulePath>/main.bicep \
  -ExcludeSections description,usage
```

## Run Tests

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path ./util/bicep-docs/tests/New-BicepReadme.Tests.ps1 -Output Detailed"
```
