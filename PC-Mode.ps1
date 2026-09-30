. (Join-Path $PSScriptRoot 'Common.ps1')

Invoke-SwitchAction 'PC MODE' { param($cfg) Invoke-PCMode $cfg }
