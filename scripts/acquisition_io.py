"""Failure-safe helpers for AD4630 dual-channel capture and transfer."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import shlex
import time
from typing import Callable

import numpy as np


WORDS_PER_FRAME = 2
BYTES_PER_WORD = 4
BYTES_PER_FRAME = WORDS_PER_FRAME * BYTES_PER_WORD
_IO_CHUNK_SIZE = 32768
_MAX_REMOTE_OUTPUT_BYTES = 16384


class AcquisitionError(RuntimeError):
    """Base class for acquisition failures that must abort the save path."""


class CaptureTimeoutError(AcquisitionError):
    """The remote capture did not finish before its deadline."""


class RemoteCaptureError(AcquisitionError):
    """The remote command failed or its SSH channel became unusable."""

    def __init__(self, message: str, *, exit_code: int | None = None,
                 stderr: str = "") -> None:
        super().__init__(message)
        self.exit_code = exit_code
        self.stderr = stderr


class CaptureDataError(AcquisitionError):
    """The captured binary does not match the expected frame contract."""


@dataclass(frozen=True)
class RemoteCaptureResult:
    exit_code: int
    stdout: str
    stderr: str


def expected_capture_bytes(samples: int) -> int:
    """Return the exact binary size for a dual-channel capture."""
    if not isinstance(samples, int) or isinstance(samples, bool) or samples <= 0:
        raise ValueError("samples must be a positive integer")
    return samples * BYTES_PER_FRAME


def ensure_output_directory(path: str | Path) -> Path:
    """Create and return the configured host output directory."""
    output_dir = Path(path)
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir


def build_remote_capture_command(
    samples: int,
    buffer_size: int,
    sample_rate: int,
    remote_path: str,
) -> str:
    """Build the board-side local-IIO capture command."""
    expected_capture_bytes(samples)
    if not isinstance(buffer_size, int) or buffer_size <= 0:
        raise ValueError("buffer_size must be a positive integer")
    if not isinstance(sample_rate, int) or sample_rate <= 0:
        raise ValueError("sample_rate must be a positive integer")
    if not remote_path:
        raise ValueError("remote_path must not be empty")

    quoted_path = shlex.quote(remote_path)
    return (
        f"rm -f -- {quoted_path} && "
        f"iio_attr -u local: -d ad4630-24 sampling_frequency {sample_rate} && "
        f"iio_readdev -u local: -b {buffer_size} -s {samples} ad4630-24"
        f" > {quoted_path}"
    )


def _append_bounded(buffer: bytearray, data: bytes) -> None:
    buffer.extend(data)
    if len(buffer) > _MAX_REMOTE_OUTPUT_BYTES:
        del buffer[:-_MAX_REMOTE_OUTPUT_BYTES]


def _drain_channel(channel, stdout_buffer: bytearray,
                   stderr_buffer: bytearray) -> None:
    while channel.recv_ready():
        _append_bounded(stdout_buffer, channel.recv(_IO_CHUNK_SIZE))
    while channel.recv_stderr_ready():
        _append_bounded(stderr_buffer, channel.recv_stderr(_IO_CHUNK_SIZE))


def run_remote_capture(
    ssh,
    samples: int,
    buffer_size: int,
    sample_rate: int,
    remote_path: str,
    timeout_s: float,
    *,
    poll_interval_s: float = 0.1,
    progress_callback: Callable[[float], None] | None = None,
) -> RemoteCaptureResult:
    """Run capture synchronously and fail closed on timeout or remote error."""
    if timeout_s <= 0:
        raise ValueError("timeout_s must be positive")
    if poll_interval_s <= 0:
        raise ValueError("poll_interval_s must be positive")

    command = build_remote_capture_command(
        samples, buffer_size, sample_rate, remote_path
    )

    try:
        stdin, stdout, _stderr = ssh.exec_command(command)
        stdin.close()
        channel = stdout.channel
    except Exception as exc:
        raise RemoteCaptureError(
            f"Could not start remote capture: {exc}"
        ) from exc

    stdout_buffer = bytearray()
    stderr_buffer = bytearray()
    start = time.monotonic()

    try:
        while not channel.exit_status_ready():
            _drain_channel(channel, stdout_buffer, stderr_buffer)
            elapsed = time.monotonic() - start
            if progress_callback is not None:
                progress_callback(elapsed)
            if elapsed >= timeout_s:
                channel.close()
                raise CaptureTimeoutError(
                    f"Remote capture exceeded {timeout_s:.1f} seconds"
                )
            time.sleep(min(poll_interval_s, max(0.0, timeout_s - elapsed)))

        _drain_channel(channel, stdout_buffer, stderr_buffer)
        exit_code = channel.recv_exit_status()
        _drain_channel(channel, stdout_buffer, stderr_buffer)
    except CaptureTimeoutError:
        raise
    except Exception as exc:
        try:
            channel.close()
        except Exception:
            pass
        raise RemoteCaptureError(
            f"Remote capture channel failed: {exc}"
        ) from exc

    stdout_text = stdout_buffer.decode("utf-8", errors="replace").strip()
    stderr_text = stderr_buffer.decode("utf-8", errors="replace").strip()
    result = RemoteCaptureResult(exit_code, stdout_text, stderr_text)

    if exit_code != 0:
        detail = stderr_text or stdout_text or "no remote diagnostic output"
        raise RemoteCaptureError(
            f"Remote capture exited with code {exit_code}: {detail}",
            exit_code=exit_code,
            stderr=stderr_text,
        )

    return result


def pull_capture(
    ssh,
    remote_path: str,
    local_path: str | Path,
    expected_samples: int,
) -> None:
    """Transfer a capture only when remote and local sizes are exact."""
    expected_bytes = expected_capture_bytes(expected_samples)
    local_path = Path(local_path)
    local_path.parent.mkdir(parents=True, exist_ok=True)

    sftp = ssh.open_sftp()
    try:
        remote_size = sftp.stat(remote_path).st_size
        if remote_size != expected_bytes:
            raise CaptureDataError(
                "Remote capture size mismatch: "
                f"expected {expected_bytes} bytes, found {remote_size}"
            )
        sftp.get(remote_path, str(local_path))
    except CaptureDataError:
        raise
    except Exception as exc:
        raise AcquisitionError(f"Capture transfer failed: {exc}") from exc
    finally:
        sftp.close()

    local_size = local_path.stat().st_size
    if local_size != expected_bytes:
        raise CaptureDataError(
            "Local capture size mismatch after transfer: "
            f"expected {expected_bytes} bytes, found {local_size}"
        )


def parse_binary_dual(
    filepath: str | Path,
    *,
    expected_samples: int | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Parse explicit little-endian dual-channel int32 frames."""
    filepath = Path(filepath)
    size_bytes = filepath.stat().st_size

    if size_bytes == 0:
        raise CaptureDataError("Capture file is empty")
    if size_bytes % BYTES_PER_FRAME != 0:
        raise CaptureDataError(
            f"Capture size {size_bytes} is not divisible by "
            f"the {BYTES_PER_FRAME}-byte frame size"
        )

    frame_count = size_bytes // BYTES_PER_FRAME
    if expected_samples is not None:
        expected_bytes = expected_capture_bytes(expected_samples)
        if size_bytes != expected_bytes:
            raise CaptureDataError(
                "Capture frame count mismatch: "
                f"expected {expected_samples} frames/{expected_bytes} bytes, "
                f"found {frame_count} frames/{size_bytes} bytes"
            )

    raw = np.fromfile(filepath, dtype="<i4")
    if raw.size != frame_count * WORDS_PER_FRAME:
        raise CaptureDataError(
            f"Read {raw.size} words but expected "
            f"{frame_count * WORDS_PER_FRAME}"
        )

    raw = raw.reshape(frame_count, WORDS_PER_FRAME)
    ch0_raw = (raw[:, 0] >> 8).astype(np.int32, copy=False)
    ch1_raw = (raw[:, 1] >> 8).astype(np.int32, copy=False)
    return ch0_raw, ch1_raw


def capture_frame_with_retry(
    ssh,
    samples: int,
    buffer_size: int,
    sample_rate: int,
    remote_path: str,
    local_path: str | Path,
    timeout_s: float,
    *,
    max_retries: int = 2,
    on_retry: Callable[[int, AcquisitionError], None] | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Capture -> transfer -> parse one dual-channel frame, with retries.

    Retries the whole capture on any AcquisitionError up to max_retries extra
    attempts. Raises the final AcquisitionError if every attempt fails, so a
    short or failed capture is never silently zero-padded by the caller.
    """
    if max_retries < 0:
        raise ValueError("max_retries must be >= 0")

    last_error: AcquisitionError | None = None
    for attempt in range(1, max_retries + 2):
        try:
            run_remote_capture(
                ssh, samples, buffer_size, sample_rate, remote_path, timeout_s
            )
            pull_capture(ssh, remote_path, local_path, samples)
            return parse_binary_dual(local_path, expected_samples=samples)
        except AcquisitionError as exc:
            last_error = exc
            if on_retry is not None and attempt <= max_retries:
                on_retry(attempt, exc)

    assert last_error is not None
    raise last_error


def cleanup_capture_resources(
    ssh,
    remote_path: str,
    local_path: str | Path | None,
) -> list[str]:
    """Best-effort cleanup that never masks the primary acquisition error."""
    warnings: list[str] = []

    if ssh is not None:
        try:
            sftp = ssh.open_sftp()
            try:
                sftp.remove(remote_path)
            except OSError as exc:
                if getattr(exc, "errno", None) != 2:
                    warnings.append(
                        f"could not remove remote temporary file: {exc}"
                    )
            finally:
                sftp.close()
        except Exception as exc:
            warnings.append(f"could not remove remote temporary file: {exc}")
        finally:
            try:
                ssh.close()
            except Exception as exc:
                warnings.append(f"could not close SSH connection: {exc}")

    if local_path is not None:
        try:
            Path(local_path).unlink(missing_ok=True)
        except Exception as exc:
            warnings.append(f"could not remove local temporary file: {exc}")

    return warnings
