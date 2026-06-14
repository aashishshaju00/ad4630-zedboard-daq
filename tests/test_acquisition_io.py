from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import acquisition_io as aio


class FakeStream:
    def __init__(self, channel=None):
        self.channel = channel
        self.closed = False

    def close(self):
        self.closed = True


class FakeChannel:
    def __init__(self, *, exit_code=0, stderr=b"", stdout=b"",
                 ready_after=0):
        self.exit_code = exit_code
        self.stderr = bytearray(stderr)
        self.stdout = bytearray(stdout)
        self.ready_after = ready_after
        self.polls = 0
        self.closed = False

    def exit_status_ready(self):
        self.polls += 1
        return self.polls > self.ready_after

    def recv_ready(self):
        return bool(self.stdout)

    def recv_stderr_ready(self):
        return bool(self.stderr)

    def recv(self, size):
        data = bytes(self.stdout[:size])
        del self.stdout[:size]
        return data

    def recv_stderr(self, size):
        data = bytes(self.stderr[:size])
        del self.stderr[:size]
        return data

    def recv_exit_status(self):
        return self.exit_code

    def close(self):
        self.closed = True


class FakeSFTP:
    def __init__(self, *, remote_bytes=b"", fail_remove=False,
                 downloaded_bytes=None):
        self.remote_bytes = remote_bytes
        self.fail_remove = fail_remove
        self.downloaded_bytes = downloaded_bytes
        self.closed = False
        self.removed = []
        self.get_calls = 0

    def stat(self, _path):
        return type("Stat", (), {"st_size": len(self.remote_bytes)})()

    def get(self, _remote_path, local_path):
        self.get_calls += 1
        data = (
            self.remote_bytes
            if self.downloaded_bytes is None
            else self.downloaded_bytes
        )
        Path(local_path).write_bytes(data)

    def remove(self, path):
        if self.fail_remove:
            raise OSError("remove failed")
        self.removed.append(path)

    def close(self):
        self.closed = True


class FakeSSH:
    def __init__(self, *, channel=None, sftp=None, exec_error=None):
        self.channel = channel
        self.sftp = sftp
        self.exec_error = exec_error
        self.closed = False
        self.command = None
        self.stdin = None

    def exec_command(self, command):
        if self.exec_error is not None:
            raise self.exec_error
        self.command = command
        self.stdin = FakeStream()
        return self.stdin, FakeStream(self.channel), FakeStream(self.channel)

    def open_sftp(self):
        if self.sftp is None:
            raise RuntimeError("SFTP unavailable")
        return self.sftp

    def close(self):
        self.closed = True


class ParseBinaryTests(unittest.TestCase):
    def test_parses_explicit_little_endian_signed_24_bit_counts(self):
        frames = np.array(
            [
                [1 << 8, -1 << 8],
                [0x007FFFFF << 8, -0x00800000 << 8],
            ],
            dtype="<i4",
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "capture.bin"
            frames.tofile(path)
            ch0, ch1 = aio.parse_binary_dual(path, expected_samples=2)

        np.testing.assert_array_equal(ch0, np.array([1, 0x007FFFFF]))
        np.testing.assert_array_equal(ch1, np.array([-1, -0x00800000]))

    def test_rejects_non_frame_aligned_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "capture.bin"
            path.write_bytes(b"\x00" * 12)
            with self.assertRaisesRegex(
                aio.CaptureDataError, "not divisible"
            ):
                aio.parse_binary_dual(path)

    def test_rejects_short_and_oversized_captures(self):
        for frame_count in (1, 3):
            with self.subTest(frame_count=frame_count):
                with tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "capture.bin"
                    path.write_bytes(
                        b"\x00" * frame_count * aio.BYTES_PER_FRAME
                    )
                    with self.assertRaisesRegex(
                        aio.CaptureDataError, "frame count mismatch"
                    ):
                        aio.parse_binary_dual(path, expected_samples=2)


class RemoteCaptureTests(unittest.TestCase):
    def test_successful_capture_returns_diagnostics(self):
        channel = FakeChannel(stdout=b"configured\n", ready_after=1)
        ssh = FakeSSH(channel=channel)

        result = aio.run_remote_capture(
            ssh, 10, 8, 500000, "/tmp/capture.bin", 1,
            poll_interval_s=0.001,
        )

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stdout, "configured")
        self.assertTrue(ssh.stdin.closed)
        self.assertIn("rm -f -- /tmp/capture.bin", ssh.command)

    def test_nonzero_exit_includes_remote_stderr(self):
        channel = FakeChannel(exit_code=17, stderr=b"iio_readdev failed\n")
        ssh = FakeSSH(channel=channel)

        with self.assertRaisesRegex(
            aio.RemoteCaptureError, "iio_readdev failed"
        ) as caught:
            aio.run_remote_capture(
                ssh, 10, 8, 500000, "/tmp/capture.bin", 1
            )

        self.assertEqual(caught.exception.exit_code, 17)
        self.assertEqual(caught.exception.stderr, "iio_readdev failed")

    def test_start_exception_is_wrapped(self):
        ssh = FakeSSH(exec_error=OSError("network unavailable"))
        with self.assertRaisesRegex(
            aio.RemoteCaptureError, "network unavailable"
        ):
            aio.run_remote_capture(
                ssh, 10, 8, 500000, "/tmp/capture.bin", 1
            )

    def test_timeout_closes_remote_channel(self):
        channel = FakeChannel(ready_after=10000)
        ssh = FakeSSH(channel=channel)

        with self.assertRaises(aio.CaptureTimeoutError):
            aio.run_remote_capture(
                ssh, 10, 8, 500000, "/tmp/capture.bin", 0.002,
                poll_interval_s=0.001,
            )

        self.assertTrue(channel.closed)


class TransferAndCleanupTests(unittest.TestCase):
    def test_output_directory_is_created_recursively(self):
        with tempfile.TemporaryDirectory() as tmp:
            output_dir = Path(tmp) / "nested" / "captures"
            result = aio.ensure_output_directory(output_dir)

            self.assertEqual(result, output_dir)
            self.assertTrue(output_dir.is_dir())

    def test_remote_size_mismatch_aborts_before_download(self):
        sftp = FakeSFTP(remote_bytes=b"\x00" * 8)
        ssh = FakeSSH(sftp=sftp)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(
                aio.CaptureDataError, "Remote capture size mismatch"
            ):
                aio.pull_capture(
                    ssh, "/tmp/capture.bin",
                    Path(tmp) / "capture.bin", expected_samples=2,
                )

        self.assertEqual(sftp.get_calls, 0)
        self.assertTrue(sftp.closed)

    def test_local_size_mismatch_after_download_is_rejected(self):
        expected = b"\x00" * 16
        sftp = FakeSFTP(
            remote_bytes=expected,
            downloaded_bytes=b"\x00" * 8,
        )
        ssh = FakeSSH(sftp=sftp)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(
                aio.CaptureDataError, "Local capture size mismatch"
            ):
                aio.pull_capture(
                    ssh, "/tmp/capture.bin",
                    Path(tmp) / "capture.bin", expected_samples=2,
                )

        self.assertTrue(sftp.closed)

    def test_cleanup_removes_local_and_closes_everything(self):
        sftp = FakeSFTP(fail_remove=True)
        ssh = FakeSSH(sftp=sftp)
        with tempfile.TemporaryDirectory() as tmp:
            local_path = Path(tmp) / "capture.bin"
            local_path.write_bytes(b"partial")
            warnings = aio.cleanup_capture_resources(
                ssh, "/tmp/capture.bin", local_path
            )
            self.assertFalse(local_path.exists())

        self.assertTrue(sftp.closed)
        self.assertTrue(ssh.closed)
        self.assertEqual(
            warnings,
            ["could not remove remote temporary file: remove failed"],
        )


class CaptureRetryTests(unittest.TestCase):
    def test_returns_on_first_success(self):
        expected = (np.arange(3, dtype=np.int32), np.arange(3, dtype=np.int32))
        with mock.patch.multiple(
            aio,
            run_remote_capture=mock.DEFAULT,
            pull_capture=mock.DEFAULT,
            parse_binary_dual=mock.DEFAULT,
        ) as mocks:
            mocks["parse_binary_dual"].return_value = expected
            retries = []
            ch0, ch1 = aio.capture_frame_with_retry(
                object(), 3, 8, 500000, "/r", "/l", 1.0,
                on_retry=lambda attempt, exc: retries.append(attempt),
            )

        np.testing.assert_array_equal(ch0, expected[0])
        np.testing.assert_array_equal(ch1, expected[1])
        self.assertEqual(mocks["run_remote_capture"].call_count, 1)
        self.assertEqual(retries, [])

    def test_retries_then_succeeds(self):
        expected = (np.zeros(2, dtype=np.int32), np.ones(2, dtype=np.int32))
        attempts = {"n": 0}

        def flaky_run(*args, **kwargs):
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise aio.RemoteCaptureError("transient", exit_code=1)

        with mock.patch.multiple(
            aio,
            run_remote_capture=flaky_run,
            pull_capture=mock.DEFAULT,
            parse_binary_dual=mock.DEFAULT,
        ) as mocks:
            mocks["parse_binary_dual"].return_value = expected
            retries = []
            ch0, ch1 = aio.capture_frame_with_retry(
                object(), 2, 8, 500000, "/r", "/l", 1.0,
                max_retries=2,
                on_retry=lambda attempt, exc: retries.append(attempt),
            )

        self.assertEqual(attempts["n"], 2)
        self.assertEqual(retries, [1])
        np.testing.assert_array_equal(ch0, expected[0])
        np.testing.assert_array_equal(ch1, expected[1])

    def test_aborts_after_exhausting_retries(self):
        def always_fail(*args, **kwargs):
            raise aio.CaptureTimeoutError("never finishes")

        with mock.patch.multiple(
            aio,
            run_remote_capture=always_fail,
            pull_capture=mock.DEFAULT,
            parse_binary_dual=mock.DEFAULT,
        ):
            retries = []
            with self.assertRaises(aio.AcquisitionError):
                aio.capture_frame_with_retry(
                    object(), 2, 8, 500000, "/r", "/l", 1.0,
                    max_retries=2,
                    on_retry=lambda attempt, exc: retries.append(attempt),
                )

        # on_retry fires for attempts 1 and 2; attempt 3 fails and raises.
        self.assertEqual(retries, [1, 2])


if __name__ == "__main__":
    unittest.main()
