using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Build.Framework;
using Microsoft.Build.Logging;

string? outputPath = null;
string? listPath = null;
var directPaths = new List<string>();
for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--output" when i + 1 < args.Length:
            outputPath = args[++i];
            break;
        case "--list" when i + 1 < args.Length:
            listPath = args[++i];
            break;
        default:
            directPaths.Add(args[i]);
            break;
    }
}

if (listPath is not null)
{
    directPaths.AddRange(File.ReadLines(listPath).Where(line => !string.IsNullOrWhiteSpace(line)));
}

if (directPaths.Count == 0 || outputPath is null)
{
    Console.Error.WriteLine("Usage: GrantReplay --output <json> [--list <file>] [binlog ...]");
    return 2;
}

var grantPattern = new Regex(
    @"Coordinator granted (?<nodes>\d+) node\(s\) for this build\.",
    RegexOptions.Compiled | RegexOptions.CultureInvariant);
var results = new List<object>(directPaths.Count);
foreach (string inputPath in directPaths)
{
    string path = Path.GetFullPath(inputPath);
    int eventCount = 0;
    int errorCount = 0;
    int warningCount = 0;
    var grants = new List<object>();
    var waits = new List<object>();
    var replay = new BinaryLogReplayEventSource();
    replay.AnyEventRaised += (_, eventArgs) =>
    {
        eventCount++;
        if (eventArgs is BuildErrorEventArgs)
        {
            errorCount++;
        }
        else if (eventArgs is BuildWarningEventArgs)
        {
            warningCount++;
        }

        string? message = eventArgs.Message;
        if (message is null)
        {
            return;
        }

        Match match = grantPattern.Match(message);
        if (match.Success)
        {
            grants.Add(new
            {
                Nodes = int.Parse(match.Groups["nodes"].Value, CultureInfo.InvariantCulture),
                TimestampUtc = eventArgs.Timestamp.ToUniversalTime(),
                Message = message
            });
        }
        else if (message.Contains(
            "Waiting for coordinator to grant build resources...",
            StringComparison.Ordinal))
        {
            waits.Add(new
            {
                TimestampUtc = eventArgs.Timestamp.ToUniversalTime(),
                Message = message
            });
        }
    };
    replay.Replay(path);
    results.Add(new
    {
        Path = path,
        EventCount = eventCount,
        ErrorCount = errorCount,
        WarningCount = warningCount,
        Grants = grants,
        Waits = waits
    });
}

var options = new JsonSerializerOptions { WriteIndented = true };
File.WriteAllText(outputPath, JsonSerializer.Serialize(results, options));
return 0;
