#requires -version 7
#requires -module InvokeBuild
using namespace System.Management.Automation

param(
    # The version of the module. Defaults to 0.0.1-dev for local builds.
    [SemanticVersion]$Version,

    [string]$ModuleName = 'Pulse',

    [string]$PublishPath = (Join-Path $PSScriptRoot 'Artifacts\Module'),

    # Use to run a specific test by name
    [string]$TestName,

    [ValidateNotNullOrWhiteSpace()]
    [string]$ManifestPath = (Join-Path $PublishPath "$ModuleName.psd1"),

    # Specify this for a non-debug release
    [switch]$Production
)

$ErrorActionPreference = 'Stop'

if (-not $Version -and $ENV:MODULE_VERSION) {
    $Version = $ENV:MODULE_VERSION
}

Set-BuildHeader {
    param($Path)
    "👷 $Path $(Get-BuildSynopsis $Task)"
}
Set-BuildFooter {
    param($Path)
    "✅ $Path $(Get-BuildSynopsis $Task)"
}

Task Clean {
    Write-Host -Fore Cyan "Cleaning publish directory: $PublishPath"
    $env:GIT_ASK_YESNO = 'false'
    git clean -fdx --no-interactive -- (Join-Path $PSScriptRoot 'Artifacts\Module') (Join-Path $PSScriptRoot 'Artifacts\*.nupkg')
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clean publish directory. Git clean exited with code $LASTEXITCODE. A file is probably locked."
    }
}

Task Compile {
    $framework = 'net8.0'
    $publishArgs = @(
        '-c', ($Production ? 'Release' : 'Debug'),
        '-f', $framework,
        '-o', (Join-Path $PSScriptRoot "Artifacts\Module\lib\$framework"),
        '-p:GenerateDocumentationFile=true',
        (Join-Path $PSScriptRoot 'Source\PowerShell\PowerShell.csproj')
    )
    dotnet publish @publishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE"
    }
}

Task CopyModuleFiles {
    $sourcePath = Join-Path $PSScriptRoot 'Source\PowerShell\Module'
    Copy-Item -Path (Join-Path $sourcePath '*') -Destination $PublishPath -Force -Recurse
}

Task Build Compile, CopyModuleFiles, {
    [SemanticVersion]$BuildVersion = $Version

    try {
        Push-Location -Path $PSScriptRoot

        $manifestPath = Resolve-Path $ManifestPath

        if ($null -eq $BuildVersion) {
            # Use git tag or a default dev version
            [SemanticVersion[]]$tag = git tag --points-at HEAD |
                ForEach-Object {
                    try {
                        [SemanticVersion]($_ -replace '^v')
                    } catch {
                        $null
                    }
                } |
                Where-Object { $_ } |
                Sort-Object -Descending

            if ($tag.Count -ge 1) {
                Write-Host -Fore Green "Using version from tag: $($tag[0])"
                $BuildVersion = $tag[0]
            } else {
                $BuildVersion = [SemanticVersion]'0.0.1-dev'
                Write-Host -Fore Yellow "No tag found. Using default dev version: $BuildVersion"
            }
        }

        Write-Host -Fore Cyan "Module Version: $BuildVersion"

        # Discover exported cmdlets from the built assembly
        $job = Start-Job -ArgumentList $ManifestPath, $ModuleName -ScriptBlock {
            param([string]$ManifestPath, [string]$ModuleName)
            Import-Module -Name $ManifestPath -Force
            @{
                CmdletsToExport = (Get-Command -CommandType Cmdlet -Module $ModuleName).Name
                AliasesToExport  = (Get-Alias | Where-Object { $_.ResolvedCommand.Module.Name -eq $ModuleName }).Name
            }
        }
        $jobOutput = Receive-Job -Job $job -Wait -AutoRemoveJob

        $updateManifestSplat = @{
            Path            = $manifestPath
            CmdletsToExport = $jobOutput.CmdletsToExport
            AliasesToExport  = $jobOutput.AliasesToExport
            ModuleVersion   = [version]$BuildVersion
            Prerelease      = 'PRERELEASEPLACEHOLDER'
        }
        Update-ModuleManifest @updateManifestSplat

        # Update-ModuleManifest doesn't support build labels in version strings, so patch manually.
        $manifestContent = Get-Content -Path $manifestPath -Raw
        $manifestContent = $manifestContent -replace 'PRERELEASEPLACEHOLDER', $BuildVersion.PreReleaseLabel
        Set-Content -Path $manifestPath -Value $manifestContent -NoNewline

        $SCRIPT:Version = $BuildVersion

        Write-Host -Fore Green "Build complete. Module published to $PublishPath"
    } finally {
        Pop-Location
    }
}

Task Pester {
    Start-Job -ScriptBlock {
        $config = New-PesterConfiguration
        $config.Run.Throw = $true
        if ($USING:TestName) {
            $config.Filter.FullName = $USING:TestName
        }
        Invoke-Pester -Configuration $config
    } | Receive-Job -Wait -AutoRemoveJob
}

Task Test Pester
Task . Clean, Build
