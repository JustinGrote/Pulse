# Bootstrap our custom ALCLoader for dependency isolation
$moduleName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)

$libPath = Join-Path $PSScriptRoot 'lib\net8.0'

if (-not ('Pulse.ALCLoader.LoadContext' -as [type])) {
    Add-Type -Path ([System.IO.Path]::Combine($libPath, "$moduleName.ALCLoader.dll"))
    [Pulse.ALCLoader.LoadContext]::Initialize() | Out-Null
}

# Load the binary module
Import-Module -Name (Join-Path $libPath 'Pulse.dll') -Force
