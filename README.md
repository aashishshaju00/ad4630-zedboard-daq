# Portable 24-bit, dual-channel acoustic data acquisition system

This repository documents the design, construction, and validation of a portable data acquisition (DAQ) system for broadband acoustic and ultrasonic measurements.

The system uses an Analog Devices AD4630-24 analog-to-digital converter (ADC) evaluation board and a Digilent ZedBoard with a Xilinx Zynq-7020 system-on-chip (SoC). It simultaneously samples two channels at 500 thousand samples per second (kSPS) per channel, records each capture locally on the ZedBoard, and transfers the completed data to a host computer for processing in Python and MATLAB. The main application is broadband acoustic, ultrasonic, and ultrasonic acoustic emission (UAE) measurement.

The repository is an engineering build record rather than a turnkey product. It includes the final hardware and software configuration, the measurements used to validate the system, and the reasoning behind the main design decisions.

## Validated system performance

| Parameter | Measured or configured value |
|---|---|
| Converter resolution | 24-bit, dual-channel simultaneous sampling |
| Operating sample rate | 500 kSPS per channel |
| Maximum converter capability | 2 million samples per second (MSPS) per channel |
| Measured signal-to-noise ratio (SNR) | Approximately 103.2 decibels (dB), measured from a 10-million-sample capture |
| Measured effective number of bits (ENOB) | Approximately 16.9 bits |
| Shorted-input noise | Approximately 19.9 microvolts root mean square (µV RMS) |
| Measured sample-rate stability | Approximately ±40 parts per million (ppm) |

The noise, SNR, and ENOB values describe the complete tested acquisition system. They should not be interpreted as ADC data-sheet values measured independently of the analog front end, power system, grounding, cabling, and host connection.

## Signal chain

![Deployed signal chain and power architecture](figures/02-deployed-signal-chain.png)

```text
Sensor or compatible analog source
    → external preamplifier, when required
    → ADA4945-1 fully differential amplifier on the evaluation board
    → AD4630-24 analog-to-digital converter
    → ZedBoard with Zynq-7020
    → local binary capture under embedded Linux
    → Ethernet file transfer
    → Python and MATLAB processing on the host computer
```

The analog source must be compatible with the input range, source impedance, input configuration, and bandwidth of the evaluation-board front end. The measurement wiring must also match the arrangement used during calibration.

The deployed system does not use the external anti-alias filter developed during the project. Testing showed that the ADA4945-1 analog front end (AFE) on the evaluation board already begins rolling off at approximately 48 to 53 kHz in the tested configuration. This is well below the 250 kHz Nyquist frequency at the 500 kSPS operating rate. The tested source also contains little energy in the higher-frequency region where aliasing would be a concern.

This decision applies to the tested source and AFE configuration. A different sensor, preamplifier, source bandwidth, or sample rate may require additional analog filtering. The optional filter design and its measured response are documented in [08, anti-alias filter design](docs/08-aa-filter-design.md).

### Core hardware

- **ADC platform:** Analog Devices EVAL-AD4630-24FMCZ with a dual-channel, simultaneous-sampling, 24-bit successive-approximation-register (SAR) ADC
- **Analog front end:** ADA4945-1 fully differential amplifier on the evaluation board
- **Embedded controller:** Digilent ZedBoard with a Xilinx Zynq-7020 SoC
- **Analog power:** LT3045 ultra-low-noise low-dropout regulator (LDO), supplied separately from the ZedBoard power rail
- **Host connection:** Gigabit Ethernet for Secure Shell (SSH) control and SSH File Transfer Protocol (SFTP) file transfer

### Core software

- **Python:** capture control, SSH command execution, SFTP transfer, binary parsing, calibration, Method B compensation, MATLAB data-file creation, and quick-look plots
- **MATLAB:** detailed signal analysis, system identification, validation, noise-baseline characterization, burst detection, and burst-quality assessment
- **Embedded Linux:** Analog Devices Kuiper Linux image with the Industrial Input/Output (IIO) software interface

## Main design decisions

### 1. Capture locally before transferring

The ADC data is recorded to a local binary file on the ZedBoard. The completed file is transferred to the host only after acquisition has finished.

```text
Configure ADC
    → run finite local capture
    → verify remote file size
    → transfer through SFTP
    → verify local file size
    → parse both channels
    → save raw counts and metadata
```

Network throughput is therefore not part of the real-time sampling path. A temporary change in network speed cannot directly remove samples from an acquisition that is already being recorded locally.

The capture command is still controlled through the SSH session. If that session is interrupted, the acquisition may stop. The host software treats this as a failed capture and does not continue through the normal save path.

### 2. Keep acquisition and analysis separate

Python handles the hardware-facing operations and provides an immediate quick-look result. MATLAB performs the more detailed frequency-domain analysis, system identification, and field-quality assessment.

This division keeps the ZedBoard-side process simple and allows saved captures to be processed again when the calibration, compensation parameters, or analysis procedure are updated.

### 3. Characterize the hardware before correcting it

The AFE frequency response was measured using swept-sine system identification. The results showed that the tested evaluation-board front end attenuated the signal as frequency increased.

The measured response was then used to create the Method B regularized frequency-domain compensator. The correction is therefore based on the measured behavior of each acquisition channel rather than only on nominal component values.

### 4. Preserve raw ADC counts

Normal captures save the original signed ADC counts together with the calibration and compensation metadata. Calibrated and compensated voltage signals are reconstructed during processing.

This approach preserves the original hardware output and allows older measurements to be processed again if the analysis method changes.

### 5. Reduce electrical coupling from the host

Ethernet was selected as the normal host connection because its physical interface is transformer coupled. This reduces direct conductive coupling between the host computer and the DAQ system.

This benefit can be bypassed by another conductive connection, such as the Universal Serial Bus to Universal Asynchronous Receiver-Transmitter (USB-UART) cable or grounded laboratory equipment. Unnecessary connections should therefore be removed during low-noise measurements.

## Documentation

The project documentation is organized in the order in which another engineer would normally understand and reproduce the system.

| Document | Contents |
|---|---|
| [01, system overview](docs/01-system-overview.md) | Purpose, complete architecture, design goals, and measured system characteristics |
| [02, hardware architecture](docs/02-hardware-architecture.md) | Signal chain, component selection, power arrangement, and host connection |
| [03, ZedBoard and ADC setup](docs/03-zedboard-adc-setup.md) | Hardware assembly, jumper settings, embedded Linux, static Internet Protocol (IP) configuration, and IIO checks |
| [04, data capture workflow](docs/04-data-capture-workflow.md) | Local capture, transfer, binary parsing, validation, and saved data format |
| [05, calibration and voltage conversion](docs/05-calibration-and-voltage-conversion.md) | Per-channel count-to-voltage calibration and measured noise performance |
| [06, frequency rolloff investigation](docs/06-frequency-rolloff-investigation.md) | Investigation of the measured AFE bandwidth limitation |
| [07, digital compensation](docs/07-digital-compensation.md) | Measurement-based Wiener and minimum-phase frequency-response correction |
| [08, anti-alias filter design](docs/08-aa-filter-design.md) | Design and testing of the optional external low-pass filter |
| [09, field deployment and usage](docs/09-field-deployment-and-usage.md) | Field preparation, setup, measurement procedure, shutdown, and troubleshooting |
| [10, burst-quality pipeline](docs/10-burst-quality-pipeline.md) | Site-noise characterization, burst detection, quality metrics, and operator decisions |

## Repository structure

```text
ad4630-zedboard-daq/
├── README.md
├── LICENSE
├── requirements.txt
├── docs/                     # Documents 01 to 10
├── scripts/
│   ├── start_daq_uae.py
│   ├── acquisition_io.py
│   ├── calibrate_dual.py
│   ├── calibrate_single.py
│   ├── freq_sweep_sysid_dual.py
│   ├── shutdown_zedboard.py
│   ├── sysid_analysis_dual.m
│   ├── characterize_noise_baseline.m
│   └── daq_burst_quality.m
├── tests/                    # Python unit tests for acquisition_io.py
├── figures/                  # Architecture and validation figures
├── data/                     # Local measurement-data location
├── hardware/                 # Hardware-related project files
└── references/               # Supporting reference material
```

## Main scripts

| Script | Purpose |
|---|---|
| [`start_daq_uae.py`](scripts/start_daq_uae.py) | Starts a finite dual-channel capture, transfers and checks the binary file, applies calibration and Method B compensation for the quick-look display, and saves the raw counts with metadata in a MATLAB `.mat` file |
| [`acquisition_io.py`](scripts/acquisition_io.py) | Shared acquisition module that handles remote capture, timeout detection, SFTP transfer, file-size checks, binary parsing, retries, and cleanup |
| [`calibrate_dual.py`](scripts/calibrate_dual.py) | Performs simultaneous multi-point direct-current (DC) calibration of both channels and reports the linear-fit quality and residuals |
| [`calibrate_single.py`](scripts/calibrate_single.py) | Performs multi-point DC calibration of one channel at a time for the single-ended bench arrangement |
| [`freq_sweep_sysid_dual.py`](scripts/freq_sweep_sysid_dual.py) | Records the swept-sine measurements used to characterize each AFE channel |
| [`shutdown_zedboard.py`](scripts/shutdown_zedboard.py) | Sends the remote Linux `poweroff` command and monitors the board response to confirm shutdown |
| [`sysid_analysis_dual.m`](scripts/sysid_analysis_dual.m) | Processes swept-sine data, produces the measured frequency response, fits candidate models, and calculates Method B compensation parameters |
| [`characterize_noise_baseline.m`](scripts/characterize_noise_baseline.m) | Characterizes the site noise and saves the median, median absolute deviation (MAD), short-time-energy, and line-length statistics used by the burst detector |
| [`daq_burst_quality.m`](scripts/daq_burst_quality.m) | Detects hammer-strike bursts, calculates the quality metrics, assigns verdicts, displays diagnostic figures, and saves accepted burst records |

Each executable script contains a `USER CONFIG` section near the beginning for settings such as the ZedBoard address, file paths, capture parameters, and calibration constants.

The original Analog Devices Kuiper image may use a stock SSH password. Change the default password before connecting the ZedBoard to an untrusted network.

The Python dependencies are listed in [`requirements.txt`](requirements.txt). MATLAB is required for the `.m` analysis scripts, and the burst-processing workflow requires the MATLAB Signal Processing Toolbox.

A supporting system build guide is also available in [Markdown](references/DAQ_System_Build_Guide.md) and [Portable Document Format (PDF)](references/DAQ_System_Build_Guide.pdf).

## Normal measurement workflow

The detailed procedure is provided in [09, field deployment and usage](docs/09-field-deployment-and-usage.md). The main sequence is:

1. Assemble and inspect the ZedBoard, ADC evaluation board, power system, Ethernet connection, sensor, and preamplifier.
2. Boot the ZedBoard and confirm communication through SSH and IIO.
3. Confirm that the measurement wiring matches the calibrated input arrangement.
4. Record a quiet site-noise capture.
5. Run `characterize_noise_baseline.m` and inspect the baseline result.
6. Run `start_daq_uae.py` for each measurement position.
7. Inspect the quick-look time-domain and power-spectral-density (PSD) plots.
8. Run `daq_burst_quality.m` to detect and assess the individual strikes.
9. Repeat rejected measurements before changing the sensor position or test setup.
10. Shut down the ZedBoard cleanly before removing power.

## Current project status

The following parts of the system have been completed and tested:

1. ZedBoard and AD4630 evaluation-board bring-up
2. embedded Linux and IIO configuration
3. finite local dual-channel capture
4. SSH control and SFTP file transfer
5. remote and local capture-size validation
6. shared acquisition and transfer module with Python unit tests
7. separate count-to-voltage calibration for both channels
8. AFE swept-sine system identification
9. Method B digital compensation in Python and MATLAB
10. shorted-input noise and sample-rate validation
11. external anti-alias filter design and bench testing
12. field noise-baseline characterization
13. hammer-strike burst detection and quality scoring
14. field deployment and troubleshooting documentation

The external anti-alias filter remains available as a tested optional stage, but it is not part of the deployed signal chain.

This repository records how the system was built and why the main decisions were made. Its purpose is to allow another engineer to understand, reproduce, evaluate, or extend the measurement system.
