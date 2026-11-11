import argparse
import json
import os
import tempfile
from pathlib import Path

from .models import Report
from .pipeline import analyze
from .sources import download
from .store import Store


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Detect, review and export VOD breaks")
    commands = parser.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("analyze")
    source = scan.add_mutually_exclusive_group(required=True)
    source.add_argument("--video", type=Path)
    source.add_argument("--url")
    scan.add_argument("--transcript", type=Path)
    scan.add_argument("--output", type=Path, default=Path("data/report.json"))
    scan.add_argument("--title", default="Local VOD")
    scan.add_argument("--streamer", default="Gamin4Hope")
    scan.add_argument("--interval", type=float, default=2)
    scan.add_argument("--lookback", type=float, default=60)
    scan.add_argument("--min-hits", type=int, default=2)
    scan.add_argument("--end-misses", type=int, default=2)
    scan.add_argument("--phrase", default="be right back")
    scan.add_argument("--whisper", action="store_true", help="Use optional local ASR if captions are absent")
    serve = commands.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8000)
    serve.add_argument("--data-dir", type=Path, default=Path("data"))
    export = commands.add_parser("export")
    export.add_argument("reports", nargs="*", type=Path)
    export.add_argument("--data-dir", type=Path)
    export.add_argument("--output", type=Path, default=Path("docs/data/reports.json"))
    args = parser.parse_args()
    if args.command == "serve":
        import uvicorn
        from .api import create_app
        if args.host not in {"127.0.0.1", "localhost", "::1"} and not os.environ.get("BRB_API_TOKEN"):
            parser.error("Set BRB_API_TOKEN before binding the service beyond localhost")
        uvicorn.run(create_app(args.data_dir), host=args.host, port=args.port)
    elif args.command == "export":
        reports = [Report.model_validate_json(p.read_text()).model_dump(mode="json") for p in args.reports]
        if args.data_dir:
            reports.extend(Store(args.data_dir).reports())
        if not reports:
            parser.error("Supply report JSON files or --data-dir with completed jobs")
        # Repeated VODs must not inflate aggregate totals. Last supplied wins.
        unique = {r.get("video_id") or r["id"]: r for r in reports}
        write_json(args.output, {"schema_version": 1, "reports": list(unique.values())})
        print(f"Exported {len(unique)} VOD(s) to {args.output}")
    else:
        options = dict(interval=args.interval, lookback=args.lookback, min_hits=args.min_hits,
                       end_misses=args.end_misses, phrase=args.phrase, whisper=args.whisper, streamer=args.streamer)
        if args.url:
            with tempfile.TemporaryDirectory(prefix="brb-") as tmp:
                video, captions, metadata = download(args.url, Path(tmp))
                report = analyze(video, args.transcript or captions, title=metadata["title"],
                                 source_url=metadata["url"], identifier=metadata["id"], **options)
                if metadata.get("caption_warning"):
                    report.warnings.append(metadata["caption_warning"])
        else:
            report = analyze(args.video, args.transcript, title=args.title, **options)
        write_json(args.output, report.model_dump(mode="json"))
        print(f"Found {len(report.breaks)} break(s); report: {args.output}")


if __name__ == "__main__":
    main()
