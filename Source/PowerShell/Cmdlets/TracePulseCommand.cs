namespace Pulse.PowerShell.Cmdlets;

using System.Collections.ObjectModel;
using System.Collections.Concurrent;
using System.Management.Automation.Runspaces;

using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

/// <summary>
/// Executes a PowerShell ScriptBlock and wraps the execution in an OpenTelemetry
/// trace span. All PowerShell output streams are captured, re-emitted on their
/// original streams, and reported as span events so that errors, warnings, and
/// informational messages are visible in the trace.
/// </summary>
[Cmdlet(VerbsDiagnostic.Trace, "PulseCommand")]
[OutputType(typeof(PSObject))]
public sealed class TracePulseCommand : PSCmdlet
{
    // Shared ActivitySource for all Pulse traces.
    private static readonly ActivitySource ActivitySource = new("Pulse", "1.0.0");

    // TracerProvider cache keyed by a stable string that encodes the exporter config.
    private static readonly ConcurrentDictionary<string, TracerProvider> ProviderCache = new();

    /// <summary>The ScriptBlock to execute and trace.</summary>
    [Parameter(Mandatory = true, Position = 0, ValueFromPipeline = true)]
    [ValidateNotNull]
    public ScriptBlock ScriptBlock { get; set; } = null!;

    /// <summary>
    /// Display name for the root span. Defaults to "PowerShell ScriptBlock".
    /// </summary>
    [Parameter(Position = 1)]
    [ValidateNotNullOrEmpty]
    public string Name { get; set; } = "PowerShell ScriptBlock";

    /// <summary>
    /// OTLP collector endpoint URL (e.g. "http://localhost:4317").
    /// Falls back to the OTEL_EXPORTER_OTLP_ENDPOINT environment variable.
    /// </summary>
    [Parameter]
    public string? OtlpEndpoint { get; set; }

    /// <summary>
    /// Emit spans to the console. Useful for development and testing.
    /// </summary>
    [Parameter]
    public SwitchParameter ConsoleExporter { get; set; }

    /// <summary>
    /// Block until all telemetry has been flushed to the configured exporters
    /// before returning. Use this when you need to guarantee delivery before
    /// the process exits.
    /// </summary>
    [Parameter]
    public SwitchParameter Wait { get; set; }

    /// <inheritdoc />
    protected override void ProcessRecord()
    {
        // Determine the effective OTLP endpoint (parameter takes precedence over env var).
        string? endpoint = OtlpEndpoint
            ?? Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT");

        bool useConsole = ConsoleExporter.IsPresent;

        // Warn when no exporter is configured so the user knows telemetry is a no-op.
        if (string.IsNullOrEmpty(endpoint) && !useConsole)
        {
            WriteWarning(
                "Trace-PulseCommand: No exporter configured. " +
                "Specify -OtlpEndpoint, -ConsoleExporter, or set the " +
                "OTEL_EXPORTER_OTLP_ENDPOINT environment variable. " +
                "The ScriptBlock will still run, but no telemetry will be exported."
            );
        }

        TracerProvider provider = GetOrBuildProvider(endpoint, useConsole);

        using Activity? activity = ActivitySource.StartActivity(Name, ActivityKind.Internal);

        // Attach basic metadata to the span.
        activity?.SetTag("host.name", Environment.MachineName);
        activity?.SetTag("ps.scriptblock", ScriptBlock.ToString());

        bool hasFailed = false;

        try
        {
            // Invoke the ScriptBlock in the current runspace, redirecting all
            // streams to the success stream so we can inspect and re-emit each record.
            Collection<PSObject> results = InvokeScriptBlock(ScriptBlock);

            foreach (PSObject item in results)
            {
                ProcessOutputItem(item, activity, ref hasFailed);
            }
        }
        catch (RuntimeException ex)
        {
            hasFailed = true;
            RecordException(activity, ex);
            WriteError(new ErrorRecord(
                ex,
                "TracePulseCommandRuntimeError",
                ErrorCategory.NotSpecified,
                ScriptBlock
            ));
        }
        catch (Exception ex)
        {
            hasFailed = true;
            RecordException(activity, ex);
            ThrowTerminatingError(new ErrorRecord(
                ex,
                "TracePulseCommandFatalError",
                ErrorCategory.NotSpecified,
                ScriptBlock
            ));
        }
        finally
        {
            activity?.SetStatus(hasFailed ? ActivityStatusCode.Error : ActivityStatusCode.Ok);
        }

        if (Wait.IsPresent)
        {
            provider.ForceFlush();
        }
    }

    // ---------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------

    /// <summary>
    /// Invokes <paramref name="scriptBlock"/> in the current runspace with all
    /// streams merged into the success stream.
    /// </summary>
    private Collection<PSObject> InvokeScriptBlock(ScriptBlock scriptBlock)
    {
        // Use a new PowerShell instance bound to the current runspace so that
        // the ScriptBlock has access to the caller's variables and functions.
        using var ps = System.Management.Automation.PowerShell.Create(RunspaceMode.CurrentRunspace);

        // *>&1 merges all streams (error, warning, verbose, debug, information)
        // into the success stream so we can inspect each record's type.
        ps.AddScript("param($__sb) & $__sb *>&1")
          .AddParameter("__sb", scriptBlock);

        return ps.Invoke();
    }

    /// <summary>
    /// Re-emits <paramref name="item"/> on the appropriate PowerShell stream and
    /// records relevant items as OpenTelemetry span events.
    /// </summary>
    private void ProcessOutputItem(PSObject item, Activity? activity, ref bool hasFailed)
    {
        switch (item.BaseObject)
        {
            case ErrorRecord errorRecord:
                hasFailed = true;
                RecordException(activity, errorRecord.Exception, errorRecord.ScriptStackTrace);
                WriteError(errorRecord);
                break;

            case WarningRecord warningRecord:
                activity?.AddEvent(new ActivityEvent("warning", tags: new ActivityTagsCollection
                {
                    ["message"] = warningRecord.Message
                }));
                WriteWarning(warningRecord.Message);
                break;

            case InformationRecord informationRecord:
                activity?.AddEvent(new ActivityEvent("information", tags: new ActivityTagsCollection
                {
                    ["message"] = informationRecord.MessageData?.ToString() ?? string.Empty,
                    ["source"] = informationRecord.Source ?? string.Empty
                }));
                WriteInformation(informationRecord);
                break;

            case VerboseRecord verboseRecord:
                WriteVerbose(verboseRecord.Message);
                break;

            case DebugRecord debugRecord:
                WriteDebug(debugRecord.Message);
                break;

            default:
                WriteObject(item.BaseObject);
                break;
        }
    }

    /// <summary>
    /// Records an exception on the activity following the OpenTelemetry
    /// semantic conventions for exceptions.
    /// </summary>
    private static void RecordException(Activity? activity, Exception? exception, string? psStackTrace = null)
    {
        if (activity is null) return;

        var tags = new ActivityTagsCollection
        {
            ["exception.type"] = exception?.GetType().FullName ?? "Exception",
            ["exception.message"] = exception?.Message ?? string.Empty,
            ["exception.stacktrace"] = psStackTrace ?? exception?.StackTrace ?? string.Empty
        };

        activity.AddEvent(new ActivityEvent("exception", tags: tags));
        activity.SetStatus(ActivityStatusCode.Error, exception?.Message ?? string.Empty);
    }

    /// <summary>
    /// Returns a cached <see cref="TracerProvider"/> for the given configuration,
    /// building one if it does not yet exist.
    /// </summary>
    private static TracerProvider GetOrBuildProvider(string? otlpEndpoint, bool useConsole)
    {
        // Build a stable cache key from the config.
        string key = $"otlp={otlpEndpoint ?? string.Empty};console={useConsole}";

        return ProviderCache.GetOrAdd(key, _ =>
        {
            TracerProviderBuilder builder = Sdk.CreateTracerProviderBuilder()
                .AddSource(ActivitySource.Name)
                .SetResourceBuilder(
                    ResourceBuilder.CreateDefault()
                        .AddService("Pulse")
                        .AddAttributes([new KeyValuePair<string, object>("host.name", Environment.MachineName)])
                );

            if (!string.IsNullOrEmpty(otlpEndpoint))
            {
                builder.AddOtlpExporter(opt =>
                {
                    opt.Endpoint = new Uri(otlpEndpoint);
                });
            }

            if (useConsole)
            {
                builder.AddConsoleExporter();
            }

            return builder.Build()!;
        });
    }
}
