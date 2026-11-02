from __future__ import annotations

import asyncio
import gc
import hashlib
import io
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest
from PIL import Image
from test_backend_mvp import auth_headers, create_connector_and_session, make_client

from agent_server.infra.files.base import UploadEmpty, UploadTooLarge
from agent_server.infra.files.local import LocalFileStorage
from agent_server.services import thumbnails


def _png(width: int, height: int) -> bytes:
    image = Image.radial_gradient("L").resize((width, height)).convert("RGB")
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def test_attachment_thumbnail_renders_webp_and_is_cacheable(tmp_path):
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    data = _png(1600, 1200)

    upload = client.post(
        f"/sessions/{session_id}/attachments",
        headers=headers,
        files={"files": ("photo.png", data, "image/png")},
    )

    assert upload.status_code == 200
    body = upload.json()["attachments"][0]
    assert body["thumbnailUrl"].endswith("/thumb?w=512")

    thumbnail = client.get(body["thumbnailUrl"], headers=headers)

    assert thumbnail.status_code == 200
    assert thumbnail.headers["content-type"] == "image/webp"
    assert thumbnail.headers["cache-control"] == "private, max-age=31536000, immutable"
    assert len(thumbnail.content) < len(data) // 4
    with Image.open(io.BytesIO(thumbnail.content)) as rendered:
        assert rendered.size == (512, 384)

    cached = client.get(
        body["thumbnailUrl"],
        headers={**headers, "If-None-Match": thumbnail.headers["etag"]},
    )
    assert cached.status_code == 304


def test_attachment_thumbnail_is_not_offered_for_unreadable_images(tmp_path):
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    data = b"\x00definitely-not-an-image"

    upload = client.post(
        f"/sessions/{session_id}/attachments",
        headers=headers,
        files={"files": ("broken.png", data, "image/png")},
    )

    assert upload.status_code == 200
    body = upload.json()["attachments"][0]
    assert body["thumbnailUrl"]
    assert client.get(body["thumbnailUrl"], headers=headers).status_code == 404


def test_streamed_attachment_reads_reject_tampered_blob(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENT_SERVER_FILES_LOCAL_ROOT", str(tmp_path / "files"))
    client = make_client(tmp_path)
    _, connector_token, session_id, headers = create_connector_and_session(client)
    data = _png(64, 48)

    upload = client.post(
        f"/sessions/{session_id}/attachments",
        headers=headers,
        files={"files": ("photo.png", data, "image/png")},
    )
    assert upload.status_code == 200
    body = upload.json()["attachments"][0]
    blob = tmp_path / "files" / session_id / f"{body['fileId']}.bin"
    # Same length, different bytes: only the hash can tell.
    blob.write_bytes(bytes(byte ^ 0xFF for byte in data))

    assert client.get(body["openUrl"], headers=headers).status_code == 500
    connector_download = client.get(
        f"/api/v2/connector/sessions/{session_id}/attachments/{body['fileId']}/content",
        headers={"Authorization": f"Bearer {connector_token}"},
    )
    assert connector_download.status_code == 500


def test_attachment_thumbnail_skips_images_over_pixel_budget(tmp_path, monkeypatch):
    monkeypatch.setattr(thumbnails, "_MAX_THUMBNAIL_PIXELS", 1_000)
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)

    upload = client.post(
        f"/sessions/{session_id}/attachments",
        headers=headers,
        files={"files": ("photo.png", _png(1600, 1200), "image/png")},
    )

    assert upload.status_code == 200
    thumbnail_url = upload.json()["attachments"][0]["thumbnailUrl"]
    assert client.get(thumbnail_url, headers=headers).status_code == 404


def test_ensure_thumbnail_releases_per_file_locks(tmp_path):
    blob = tmp_path / "file_demo.bin"
    blob.write_bytes(_png(800, 600))

    async def render_concurrently():
        return await asyncio.gather(
            *(thumbnails.ensure_thumbnail(blob, 256) for _ in range(3))
        )

    results = asyncio.run(render_concurrently())

    assert results == [thumbnails.thumbnail_path(blob, 256)] * 3
    gc.collect()
    assert len(thumbnails._locks) == 0


def test_large_jpeg_gets_thumbnail_after_draft_decode(tmp_path):
    blob = tmp_path / "file_photo.bin"
    # 48 MP is over the pixel budget, but JPEG decodes at 1/4 scale here.
    Image.new("RGB", (8000, 6000), (120, 80, 40)).save(blob, "JPEG")

    thumb = asyncio.run(thumbnails.ensure_thumbnail(blob, 512))

    assert thumb == thumbnails.thumbnail_path(blob, 512)
    with Image.open(thumb) as rendered:
        assert rendered.size == (512, 384)


def test_independent_thumbnail_renderers_publish_complete_files_without_temp_collisions(
    tmp_path, monkeypatch
):
    blob = tmp_path / "file_concurrent.bin"
    blob.write_bytes(_png(800, 600))
    destination = thumbnails.thumbnail_path(blob, 256)
    saved = Barrier(2)
    original_save = Image.Image.save

    def save_before_concurrent_publish(image, path, *args, **kwargs):
        original_save(image, path, *args, **kwargs)
        saved.wait(timeout=10)

    monkeypatch.setattr(Image.Image, "save", save_before_concurrent_publish)
    # Call the renderers independently, as separate server workers do: neither
    # the per-event-loop file lock nor the render semaphore is shared.
    with ThreadPoolExecutor(max_workers=2) as workers:
        pending = [
            workers.submit(thumbnails._render, blob, destination, 256) for _ in range(2)
        ]
        results = [task.result(timeout=15) for task in pending]

    assert results == [True, True]
    with Image.open(destination) as rendered:
        rendered.load()
        assert rendered.format == "WEBP"
        assert rendered.size == (256, 192)
    assert not list(tmp_path.glob("*.part"))


def test_local_upload_stream_reads_bounded_chunks_and_publishes_verified_metadata(tmp_path):
    data = b"a" * (2 * 1024 * 1024 + 17)
    read_sizes = []

    class BoundedSource(io.BytesIO):
        def read(self, size=-1):
            assert 0 < size <= 1024 * 1024
            read_sizes.append(size)
            return super().read(size)

    storage = LocalFileStorage(tmp_path)
    result = asyncio.run(
        storage.write_stream("session_test", "file_test", BoundedSource(data), {})
    )

    assert len(read_sizes) >= 3
    assert result == {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    stored, metadata = asyncio.run(storage.read("session_test", "file_test"))
    assert stored == data
    assert metadata == result
    assert not list(tmp_path.rglob("*.part"))


@pytest.mark.parametrize("failure", ["empty", "over_limit", "read_error"])
def test_local_upload_stream_failure_does_not_publish_partial_files(tmp_path, failure):
    class BrokenSource(io.BytesIO):
        def read(self, size=-1):
            if self.tell():
                raise OSError("synthetic upload interruption")
            return super().read(4)

    storage = LocalFileStorage(tmp_path)
    source = io.BytesIO(b"")
    expected = UploadEmpty
    limit = None
    if failure == "over_limit":
        source, expected, limit = io.BytesIO(b"too large"), UploadTooLarge, 3
    elif failure == "read_error":
        source, expected = BrokenSource(b"interrupted upload"), OSError

    with pytest.raises(expected):
        asyncio.run(
            storage.write_stream("session_test", "file_test", source, {}, max_bytes=limit)
        )

    assert not asyncio.run(storage.exists("session_test", "file_test"))
    assert not list((tmp_path / "session_test").iterdir())


def test_thumbnail_requires_session_owner_authorization(tmp_path):
    client = make_client(tmp_path)
    _, _, session_id, headers = create_connector_and_session(client)
    upload = client.post(
        f"/sessions/{session_id}/attachments",
        headers=headers,
        files={"files": ("private.png", _png(64, 48), "image/png")},
    )
    assert upload.status_code == 200
    url = upload.json()["attachments"][0]["thumbnailUrl"]
    assert client.get(url).status_code == 401
    other = auth_headers(client, user_id="other-thumbnail-owner")
    assert client.get(url, headers=other).status_code == 404
