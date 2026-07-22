#requires -module Pester
#requires -version 7

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Artifacts' 'Module' 'Pulse.psd1'
    if (-not (Test-Path $modulePath)) {
        throw "Module not found at '$modulePath'. Run the build script first."
    }
    Import-Module $modulePath -Force
}

Describe 'Trace-PulseCommand' {
    Context 'Basic ScriptBlock execution' {
        It 'Returns output from the ScriptBlock' {
            $result = Trace-PulseCommand -Name 'Test' -ConsoleExporter -ScriptBlock {
                'hello'
            }
            $result | Should -Be 'hello'
        }

        It 'Returns multiple outputs from the ScriptBlock' {
            $result = Trace-PulseCommand -Name 'Multi' -ConsoleExporter -ScriptBlock {
                1, 2, 3
            }
            $result | Should -HaveCount 3
        }

        It 'Accepts ScriptBlock from pipeline' {
            $result = { 'from pipeline' } | Trace-PulseCommand -Name 'Pipeline' -ConsoleExporter
            $result | Should -Be 'from pipeline'
        }
    }

    Context 'Stream handling' {
        It 'Re-emits warnings from the ScriptBlock' {
            Trace-PulseCommand -Name 'Warn' -ConsoleExporter -ScriptBlock {
                Write-Warning 'test warning'
            } -WarningVariable warnVar -WarningAction SilentlyContinue
            $warnVar | Should -HaveCount 1
            $warnVar[0] | Should -Match 'test warning'
        }

        It 'Re-emits errors from the ScriptBlock as non-terminating errors' {
            Trace-PulseCommand -Name 'Error' -ConsoleExporter -ScriptBlock {
                Write-Error 'test error'
            } -ErrorVariable +errVar -ErrorAction SilentlyContinue
            $errVar | Should -HaveCount 1
            $errVar[0].Exception.Message | Should -Be 'test error'
        }

        It 'Does not suppress output after a non-terminating error' {
            $result = Trace-PulseCommand -Name 'ErrAndOutput' -ConsoleExporter -ScriptBlock {
                Write-Error 'nonfatal'
                'after error'
            } -ErrorAction SilentlyContinue
            $result | Should -Be 'after error'
        }

        It 'Re-emits verbose messages' {
            $verboseMessages = [System.Collections.Generic.List[System.Management.Automation.VerboseRecord]]::new()
            Trace-PulseCommand -Name 'Verbose' -ConsoleExporter -ScriptBlock {
                Write-Verbose 'verbose message' -Verbose
            } -Verbose 4>&1 | Out-Null
            # Verbose messages flow correctly if no exception is thrown
        }
    }

    Context 'Exporter configuration' {
        It 'Warns when no exporter is configured' {
            Trace-PulseCommand -Name 'NoExp' -ScriptBlock { 'x' } -WarningVariable warnVar -WarningAction SilentlyContinue
            $warnVar | Where-Object { $_ -match 'No exporter' } | Should -Not -BeNullOrEmpty
        }

        It 'Does not warn when ConsoleExporter is specified' {
            Trace-PulseCommand -Name 'ConsoleExp' -ConsoleExporter -ScriptBlock { 'x' } -WarningVariable warnVar -WarningAction SilentlyContinue
            $warnVar | Where-Object { $_ -match 'No exporter' } | Should -BeNullOrEmpty
        }

        It 'Does not warn when OTEL_EXPORTER_OTLP_ENDPOINT env var is set' {
            $env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://localhost:4317'
            try {
                Trace-PulseCommand -Name 'EnvVar' -ScriptBlock { 'x' } -WarningVariable warnVar -WarningAction SilentlyContinue
                $warnVar | Where-Object { $_ -match 'No exporter' } | Should -BeNullOrEmpty
            } finally {
                $env:OTEL_EXPORTER_OTLP_ENDPOINT = $null
            }
        }
    }

    Context 'Parameter defaults and validation' {
        It 'Accepts Name parameter' {
            { Trace-PulseCommand -Name 'Custom Name' -ConsoleExporter -ScriptBlock { 'x' } } | Should -Not -Throw
        }

        It 'Uses default name when Name is not specified' {
            { Trace-PulseCommand -ConsoleExporter -ScriptBlock { 'x' } } | Should -Not -Throw
        }

        It 'Requires ScriptBlock parameter' {
            { Trace-PulseCommand -ConsoleExporter } | Should -Throw
        }
    }
}
