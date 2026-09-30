. (Join-Path $PSScriptRoot 'Common.ps1')

Invoke-SwitchAction 'PS5 MODE' { param($cfg) Invoke-PS5Mode $cfg }
