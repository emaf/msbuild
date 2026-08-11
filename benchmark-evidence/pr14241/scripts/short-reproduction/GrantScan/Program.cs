using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Build.Logging;

var results = new List<object>(args.Length);
var grantPattern = new Regex(@"Coordinator granted (\d+) node\(s\)", RegexOptions.CultureInvariant);

foreach (string path in args)
{
    int eventCount = 0;
    var grants = new List<object>();
    var replay = new BinaryLogReplayEventSource();
    replay.AnyEventRaised += (_, eventArgs) =>
    {
        eventCount++;
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
                Nodes = int.Parse(match.Groups[1].Value),
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
        Grants = grants
    });
}

Console.Write(JsonSerializer.Serialize(results));
