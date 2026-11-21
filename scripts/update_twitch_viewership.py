"""Match published VODs to public TwitchTracker stream averages."""
import argparse
from collections import Counter
from datetime import UTC, datetime
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.request import Request, urlopen

SOURCE = "https://twitchtracker.com/gamin4hope/streams"
VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}")


class StreamsTable(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_table = False
        self.row = None
        self.cell = None
        self.past = False
        self.headers = []
        self.streams = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "table" and attrs.get("id") == "streams":
            self.in_table = True
        if not self.in_table:
            return
        if tag == "tr":
            self.row = []
            self.past = False
        elif self.row is not None and tag in ("td", "th"):
            self.cell = []
        elif self.cell is not None and attrs.get("title") == "Past Stream":
            self.past = True

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if not self.in_table:
            return
        if tag in ("td", "th") and self.cell is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            if self.past:
                self.add_stream(self.row)
            elif not self.headers and "Avg Viewers" in self.row:
                self.headers = self.row
            self.row = None
        elif tag == "table":
            self.in_table = False

    def add_stream(self, cells):
        try:
            row = dict(zip(self.headers, cells))
            # The source sends UTC here and converts it to local time in the browser.
            started = datetime.strptime(row["Stream"], "%Y-%m-%d %H:%M").replace(tzinfo=UTC)
            minutes = int(row["Duration"].replace(",", ""))
            viewers = int(row["Avg Viewers"].replace(",", ""))
        except (KeyError, ValueError):
            return
        if minutes > 0 and viewers > 0:
            self.streams.append((started, minutes, viewers))


def match_streams(reports, streams, previous):
    matches = {}
    for report in reports:
        video = report.get("video_id")
        if not isinstance(video, str) or not VIDEO_ID.fullmatch(video) or report.get("is_demo"):
            continue
        try:
            started = datetime.fromisoformat(report["stream_started_at"])
            duration = float(report["duration_seconds"])
            if started.utcoffset() is None or not 0 < duration:
                continue
        except (KeyError, TypeError, ValueError):
            continue

        # Simulcasts can start separately, and either VOD can trim a few minutes.
        # Check both ends so short or adjacent broadcasts stay separate.
        candidates = [
            (start, minutes, viewers)
            for start, minutes, viewers in streams
            if abs((started - start).total_seconds()) <= 8 * 60
            and abs((started - start).total_seconds() + duration - minutes * 60) <= 8 * 60
            and abs(duration - minutes * 60) <= 12 * 60
        ]
        if len(candidates) == 1:
            start, minutes, viewers = candidates[0]
            matches[video] = {
                "average_viewers": viewers,
                "twitch_started_at": start.isoformat(timespec="minutes"),
                "twitch_duration_minutes": minutes,
                "vod_started_at": report["stream_started_at"],
                "vod_duration_seconds": report["duration_seconds"],
            }
        elif not candidates:
            old = previous.get(video, {})
            if old.get("vod_started_at") == report["stream_started_at"] and old.get("vod_duration_seconds") == report["duration_seconds"]:
                matches[video] = old
    identities = Counter((row["twitch_started_at"], row["twitch_duration_minutes"]) for row in matches.values())
    return {
        video: row for video, row in matches.items()
        if identities[row["twitch_started_at"], row["twitch_duration_minutes"]] == 1
    }


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--html", type=Path, help="Read a saved TwitchTracker page")
    args = cli.parse_args()
    reports = json.loads(Path("docs/data/reports.json").read_text())["reports"]
    output = Path("docs/data/twitch-viewership.json")
    previous = json.loads(output.read_text())["matches"] if output.exists() else {}
    table = StreamsTable()
    if args.html:
        table.feed(args.html.read_text())
    else:
        request = Request(SOURCE, headers={"User-Agent": "BRB Tracker (public Twitch stream averages; github.com/MacTimiT/brb-tracker)"})
        with urlopen(request, timeout=20) as response:
            table.feed(response.read().decode("utf-8"))
    table.close()
    if not table.streams:
        raise SystemExit("TwitchTracker returned no readable past streams. Existing estimates were kept.")
    matches = match_streams(reports, table.streams, previous)
    output.write_text(json.dumps({"schema_version": 1, "source": SOURCE, "matches": matches}, indent=2, sort_keys=True) + "\n")
    print(f"Matched {len(matches)} of {len(reports)} published VODs.")


if __name__ == "__main__":
    main()
