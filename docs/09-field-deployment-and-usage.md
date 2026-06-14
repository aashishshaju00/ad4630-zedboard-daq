# Deployment and usage

This document is the operating guide for taking the data-acquisition (DAQ) system from the laboratory to a measurement site. It covers pre-deployment checks, field connections, the capture sequence, record keeping, clean shutdown, and common problems.

The ZedBoard and evaluation board should already be configured according to [03, ZedBoard and analog-to-digital converter setup](03-zedboard-adc-setup.md). The full procurement and assembly information is available in the [DAQ system build guide](../references/DAQ_System_Build_Guide.md).

## Field workflow

The normal field sequence is:

**prepare and test the system in the laboratory**   
→ **connect power, signal, and Ethernet**  
→ **confirm ZedBoard communication**  
→ **record a site noise baseline**  
→ **capture hammer-strike measurements**  
→ **inspect the quick-look display**  
→ **run the burst-quality pipeline**  
→ **repeat any poor measurements**  
→ **shut down the ZedBoard cleanly**


Complete the following checks before transporting the system.

### 1. Charge and test both power sources

The system uses separate power paths:

- a lithium iron phosphate (LiFePO4) battery for the ZedBoard and evaluation board
- a separate isolated 5 V supply for the external sensor preamplifier

The LiFePO4 battery has a nominal energy rating of 153 Wh. At an approximate 15 W system load, the ideal calculation gives about 10 hours of operation:

```text
ideal runtime = 153 Wh / 15 W

ideal runtime ≈ 10.2 hours
```

Actual runtime depends on:

- battery age and state of charge
- temperature
- direct-current conversion losses
- cable and connector losses
- the actual system load

If possible measure the practical runtime before a long field campaign. Do not plan a complete campaign using only the ideal energy calculation.

### 2. Run a complete test capture

In the laboratory:

1. boot the ZedBoard
2. confirm Ethernet communication
3. run a complete dual-channel capture
4. transfer the binary data
5. confirm that the MATLAB `.mat` file is saved
6. inspect the quick-look plots
7. run the burst-quality script on a representative file
8. shut down the board using the normal shutdown script

This checks the complete hardware and software path rather than only confirming that the board powers on.

### 3. Confirm network communication

The configured ZedBoard Internet Protocol (IP) address is:

```text
192.168.1.100
```

With the host computer on the same subnet, run:

```bash
iio_info -u ip:192.168.1.100
```

The output should include the `ad4630-24` Industrial Input/Output (IIO) device and both voltage channels.

This command is a bring-up and diagnostic check. Normal acquisition uses local `iio_readdev` on the ZedBoard, followed by Secure Shell (SSH) control and SSH File Transfer Protocol (SFTP) transfer.

### 4. Check storage space

At 500 kilosamples per second (kSPS), one dual-channel frame contains two 32-bit words:

```text
500,000 frames/s × 8 bytes/frame = 4,000,000 bytes/s
```

A 10-second raw capture is therefore approximately 40 megabytes (MB) before MATLAB-file compression.

Check:

- free space in the host capture directory
- free space in the ZedBoard `/tmp` location used by the capture script
- available space for burst files and campaign logs

The exact storage backing of `/tmp` depends on the installed Linux image. The operating procedure only assumes that the configured temporary location has enough available space for the requested capture.

### 5. Inspect cables

Inspect:

- Gigabit Ethernet cable
- SubMiniature version A (SMA) signal cables
- Bayonet Neill-Concelman (BNC) to SMA adapters
- ZedBoard barrel-power adapter
- sensor and preamplifier cables
- spare cables for the most failure-prone connections

Check for loose connector bodies, damaged center pins, bent contacts, and intermittent cables before leaving the laboratory.

## Field setup

Complete the setup with power removed.

### 1. Position the equipment

Place the equipment case near the measurement point without allowing it to interfere with the specimen or impact procedure.

Keep the host computer:

- on a stable surface
- protected from accidental cable pull
- protected from rain, dust, and direct heat where possible
- close enough that the operator can inspect the quick-look display

### 2. Connect the power system

Connect:

```text
LiFePO4 battery
    → DC5521-to-DC5525 adapter
    → ZedBoard J20 barrel connector
```

Connect the sensor preamplifier separately:

```text
isolated 5 V supply
    → external sensor preamplifier
```

Do not power the external preamplifier from a ZedBoard-derived supply in the tested configuration. The separate supply reduces coupling from the ZedBoard, double-data-rate memory, Ethernet physical layer, and processing system into the low-level analog signal.

The power and isolation arrangement is described in [02, hardware architecture](02-hardware-architecture.md#power-architecture).

### 3. Connect the signal

The normal signal path is:

```text
sensor
    → external preamplifier
    → BNC-to-SMA adapter
    → evaluation-board input
```

Use the same input topology that was used during calibration.

Do not change:

- driven input connector
- unused-input termination
- single-ended or differential arrangement
- signal polarity mapping
- cable configuration that materially affects loading

without checking the response and recalibrating the system.

### 4. Connect Ethernet

Connect:

```text
ZedBoard J10 Ethernet
    → host-computer Ethernet port
```

The normal field arrangement is a direct connection without a network switch.

The host Ethernet adapter should use an address on the same subnet, for example:

```text
Host:      192.168.1.10
ZedBoard:  192.168.1.100
Netmask:   255.255.255.0
```

### 5. Boot and verify

1. Apply ZedBoard power.
2. Allow approximately 30 seconds for the installed Kuiper Linux image to boot.
3. Ping `192.168.1.100`.
4. Run `iio_info -u ip:192.168.1.100`.
5. Confirm that `ad4630-24` is listed.
6. Confirm that the expected sample-rate attribute and both channels are available.

The Universal Serial Bus to Universal Asynchronous Receiver-Transmitter (USB-UART) cable is useful during setup and recovery. Disconnect it during low-noise Ethernet-controlled measurement when it is not required, because the conductive USB connection can bypass the isolation provided by the Ethernet transformer magnetics.

## Analog-input notes

The AD4630 evaluation-board front end can be used with single-ended or differential sources.

For a single-ended source, Analog Devices recommends terminating the unused input with an impedance equivalent to the driven source impedance. The single-ended bench calibration used in this project instead connected the unused negative input to evaluation-board ground.

That tested arrangement affects common-mode balance and may affect distortion, but the measured calibration constants apply to the arrangement in which they were obtained.

The ADA4945-1 fully differential amplifier also changes the polarity presented to the analog-to-digital converter (ADC). In the tested mapping, a positive source connection belongs on `IN-` and a negative source connection belongs on `IN+`. The differential sensor wiring is arranged to preserve the intended polarity.

For alternating-current (AC) burst-amplitude and spectral measurements, an overall polarity inversion may not change the primary magnitude results. It still matters when comparing time-domain polarity, phase, or multiple channels.

Record the exact wiring used during each campaign.

## Why LiFePO4 is used

The LiFePO4 battery maintains approximately 12 to 13 V through more than 90% of its discharge.

A typical three-cell lithium-ion battery can fall toward approximately 9 V as it discharges. A changing supply voltage can reduce power-converter margin or cause unstable operation near the end of a session.

The more stable LiFePO4 voltage helps keep the embedded system operating consistently. It does not remove the need to monitor battery charge and test actual runtime.

## Software configuration

Before a campaign, review the user-configuration section at the top of each script.

Important values include:

- ZedBoard IP address
- ZedBoard user name
- ZedBoard password or `ZED_PASS` environment variable
- sample rate
- capture duration
- host output directory
- calibration constants
- dataset and burst-output directories

The main scripts are:

| Purpose | Script |
|---|---|
| Dual-channel calibration | [`scripts/calibrate_dual.py`](../scripts/calibrate_dual.py) |
| Normal field capture | [`scripts/start_daq_uae.py`](../scripts/start_daq_uae.py) |
| Site noise characterization | [`scripts/characterize_noise_baseline.m`](../scripts/characterize_noise_baseline.m) |
| Burst detection and quality scoring | [`scripts/daq_burst_quality.m`](../scripts/daq_burst_quality.m) |
| Clean ZedBoard shutdown | [`scripts/shutdown_zedboard.py`](../scripts/shutdown_zedboard.py) |

## Calibration before measurement

Run the dual-channel calibration when:

- the input wiring changes
- the front end changes
- the evaluation board changes
- the termination changes
- an unexplained gain or offset shift is observed

The command is:

```bash
python calibrate_dual.py
```

Transfer the resulting Channel 0 and Channel 1 gain and offset values into the capture configuration as required.

The calibration method is described in [05, calibration and voltage conversion](05-calibration-and-voltage-conversion.md).

## Record a site noise baseline

Ambient noise changes between laboratories, field locations, mounting arrangements, and operating days.

Before applying hammer strikes:

1. install and power the sensors in their normal measurement arrangement
2. keep the specimen undisturbed
3. record approximately 10 seconds with no intentional impact
4. save the capture
5. run `characterize_noise_baseline.m`
6. inspect the diagnostic figure for accidental taps or interference
7. confirm that `noise_baseline.mat` was created in the configured data directory

The burst-quality script loads this file automatically when it is present and compatible with the capture sample rate.

The complete baseline procedure is described in [10, burst-quality pipeline](10-burst-quality-pipeline.md).

## Running a normal capture

Run:

```bash
python start_daq_uae.py
```

The normal sequence is:

1. The script selects the next available `captureN.mat` filename.
2. It connects to the ZedBoard through SSH.
3. It displays the configured sample rate, duration, sample count, and compensation method.
4. The operator presses Enter to start.
5. The script displays `RECORDING`, and the operator performs the hammer strikes.
6. `iio_readdev` records the requested sample count to `/tmp/capture.bin` on the ZedBoard.
7. The completed binary file is checked and transferred through SFTP.
8. The two channels are parsed and calibrated.
9. Method B compensation is applied for the quick-look display.
10. Raw counts and metadata are saved to the host `.mat` file.
11. The dual-channel time-domain and power-spectral-density plots are displayed.
12. Temporary files and communication resources are cleaned up.

The detailed implementation is described in [04, data capture workflow](04-data-capture-workflow.md).

## Per-measurement loop

For each specimen and measurement point:

1. Place and secure the sensor at the designated position.
2. Record the specimen identifier, measurement point, sensor position, date, and time.
3. Confirm that cables are not under tension and will not move during impact.
4. Start `start_daq_uae.py`.
5. Press Enter when the specimen and operator are ready.
6. Apply the expected hammer strikes while `RECORDING` is displayed.
7. Wait for capture, transfer, processing, and file save to complete.
8. Inspect both channels in the quick-look plots.
9. Confirm that the expected `.mat` file exists.
10. Rename or organize the capture according to the burst-pipeline naming convention.
11. Run the burst-quality assessment.
12. Repeat the measurement before moving the sensor if the strikes are rejected.

For the current batch pipeline, capture filenames use:

```text
Specimen_<number>_<measurement point>.mat
```

Example:

```text
Specimen_5_P1.mat
```

The burst script currently defines measurement points `P1` through `P6`. Update its configuration if a campaign uses a different set.

## Quick-look acceptance checks

Before accepting a capture, check:

- both channels contain the expected response
- no channel is unexpectedly flat
- no obvious clipping is visible
- the voltage range is plausible
- the strike count appears reasonable
- dominant spectral content is plausible
- there is no strong unexplained interference
- the saved filename matches the field record

The quick-look display is not the final strike-quality decision. The MATLAB burst-quality pipeline performs the detailed detection and scoring.

## Clean shutdown

Before disconnecting ZedBoard power, run:

```bash
python shutdown_zedboard.py
```

The script:

1. connects to the ZedBoard using SSH
2. issues the Linux `poweroff` command
3. waits for the SSH connection to close
4. sends one Internet Control Message Protocol (ICMP) ping per second
5. requires five consecutive failed pings
6. stops waiting after a 60-second timeout

Five consecutive ping failures are the script's remote shutdown criterion. A network failure can produce the same observation, so confirm the final board state using indicators or the serial console when practical before removing power.

If the board still responds after the timeout, do not remove power. Connect through the UART console and inspect the operating-system state.

## Troubleshooting

### Host cannot reach the ZedBoard

1. Confirm that the host and ZedBoard are on the same subnet.
2. Confirm the host static IP address.
3. Reseat both Ethernet connectors.
4. Replace the Ethernet cable.
5. Check the host firewall and network-adapter status.
6. Use the USB-UART console if the static IP configuration is incorrect.

### `iio_info` connects but `ad4630-24` is missing

Check:

1. the Secure Digital (SD) card is seated correctly
2. the Kuiper image completed booting
3. the evaluation board is fully seated on the Field-Programmable Gate Array (FPGA) Mezzanine Card (FMC) connector
4. adjustable input/output voltage (VADJ) is set to 2.5 V
5. the required field-programmable gate array configuration and device tree loaded

Power-cycle the system after correcting the hardware or boot configuration.

### Captures are noisy

Check:

- the preamplifier is powered by the separate isolated 5 V supply
- the USB-UART cable is disconnected when it is not required
- analog cables are separated from digital and power cables
- the shield and grounding arrangement matches the tested configuration
- connectors are tight
- the sensor is mounted consistently
- the noise baseline has not shifted by more than expected

### Capture timeout or incomplete file

Check:

1. available space in the configured ZedBoard temporary location
2. available host storage
3. Ethernet stability
4. SSH and SFTP access on port 22
5. whether another process is using the IIO device
6. whether the configured capture timeout is long enough

Reducing the sample rate or buffer size can be used as a diagnostic test. Restore the validated measurement configuration after identifying the problem.

The IIO daemon port `30431` is used for diagnostic network-IIO access. It is not the normal capture-and-transfer path.

### Network configuration is unusable

Use the USB-UART console described in [03, ZedBoard and analog-to-digital converter setup](03-zedboard-adc-setup.md#7-serial-login). The serial console does not require Ethernet.

## Deployment summary

1. Test the complete system before leaving the laboratory.
2. Use separate power for the ZedBoard and the external preamplifier.
3. Preserve the calibrated analog-input arrangement.
4. Use direct Ethernet for command control and file transfer.
5. Record a site-specific noise baseline before hammer strikes.
6. Keep a written mapping between filenames, specimens, and measurement points.
7. Inspect the quick-look plots after every capture.
8. Use the burst-quality pipeline before leaving the measurement point.
9. Repeat rejected measurements while the setup is still available.
10. Shut down the ZedBoard cleanly before removing power.
