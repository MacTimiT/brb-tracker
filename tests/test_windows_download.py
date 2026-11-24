import functools
import http.server
import threading
import time

import yt_dlp

from brb_tracker.sources import download


def test_media_download_obeys_configured_byte_rate(tmp_path, monkeypatch, capsys):
    payload = b"\x00" * (256 * 1024)
    served = tmp_path / "source"
    served.mkdir()
    (served / "fixture.mp4").write_bytes(payload)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=served)

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        asset = f"http://127.0.0.1:{server.server_port}/fixture.mp4"

        class FixtureDownloader(yt_dlp.YoutubeDL):
            def extract_info(self, url, download=True, **kwargs):
                return self.process_ie_result({
                    "id": "fixture0001",
                    "title": "Local transfer fixture",
                    "formats": [{
                        "url": asset, "ext": "mp4", "format_id": "direct",
                        "height": 360, "vcodec": "avc1", "acodec": "aac",
                    }],
                }, download=download)

        monkeypatch.setattr(yt_dlp, "YoutubeDL", FixtureDownloader)
        updates = []
        try:
            started = time.monotonic()
            video, _, _ = download(
                "https://youtu.be/fixture0001", tmp_path / "download",
                rate_limit=128 * 1024, progress=updates.append, fetch_captions=False,
            )
            elapsed = time.monotonic() - started
        finally:
            server.shutdown()
            worker.join()

    assert video.read_bytes() == payload
    assert elapsed >= 1.8
    assert any(update["status"] == "downloading" for update in updates)
    assert updates[-1]["status"] == "finished"
    assert "[download]" not in capsys.readouterr().out
