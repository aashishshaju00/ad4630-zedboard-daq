# System overview

## Purpose

This project documents the design, construction, and validation of a portable 24-bit data acquisition (DAQ) system for high-resolution broadband measurements. The system combines a precision analog-to-digital converter (ADC), an embedded Linux controller, Ethernet file transfer, calibrated voltage reconstruction, and post-processing in Python and MATLAB.

The system has mainly been used to measure acoustic and ultrasonic signals, including short-duration impact responses and acoustic-emission events. The same architecture can also be used with other compatible analog sources, provided that the source voltage, source impedance, input configuration, and bandwidth are suitable for the ADC front end.

The main system requirements were:

1. High dynamic range for low-amplitude measurements.
2. Simultaneous sampling of two input channels.
3. Reliable capture of broadband transient signals.
4. Reliable communication between the embedded controller and the host computer.
5. Repeatable conversion from raw ADC counts to voltage.
6. Measured validation of the analog front end (AFE).
7. A processing workflow that preserves the original raw data.

This repository is intended to be an engineering record of the completed system. It documents not only the final hardware and software configuration, but also the measurements and decisions that led to it.

## What the system does

The system accepts an analog input signal, samples both ADC channels simultaneously, stores the acquired data locally on the ZedBoard, and transfers the completed capture to a host computer over Ethernet. The host software then converts the raw ADC counts into calibrated voltage signals and performs the required signal processing.

The workflow is divided into two main layers:

1. **Acquisition layer**
   - controls the ZedBoard and ADC
   - sets the sample rate
   - starts and monitors each capture
   - transfers the completed binary file
   - checks that the capture contains the expected number of samples

2. **Analysis layer**
   - converts raw ADC counts to voltage
   - applies the measured front-end compensation
   - produces time-domain and frequency-domain plots
   - performs system validation
   - detects and evaluates impact bursts

Keeping acquisition and analysis separate reduces the amount of processing required on the ZedBoard. It also allows an old capture to be processed again if the calibration constants, compensation method, or analysis procedure are updated.

## Full signal chain

The deployed measurement chain is:

**Differential analog source or sensor with preamplifier**  
→ **ADA4945-1 fully differential amplifier on the EVAL-AD4630-24FMCZ**  
→ **AD4630-24 dual-channel ADC**  
→ **ZedBoard with Xilinx Zynq-7020**  
→ **local binary capture under embedded Linux**  
→ **SSH File Transfer Protocol (SFTP) transfer over Ethernet**  
→ **Python and MATLAB processing on the host computer**

In compact form:

```text
Sensor or analog source
    → preamplifier
    → ADA4945-1 analog front end
    → AD4630-24 ADC
    → Zynq-7020 programmable logic and Linux
    → local binary file
    → Ethernet transfer
    → calibrated and compensated analysis
```

The AD4630 evaluation board can be configured for either a single-ended or differential source. The measurement wiring must match the wiring used during calibration. Changing the driven input, grounding arrangement, source impedance, or connector polarity can change the sign, offset, common-mode balance, or distortion of the measured signal.

The complete acquisition path has been tested using:

- direct-current (DC) calibration levels
- sinusoidal frequency sweeps
- fixed-frequency sinusoidal signals
- square waves
- impulsive and hammer-strike signals

These tests were used to check voltage scaling, sample integrity, frequency response, transient behavior, and the final burst-analysis workflow.

## Core hardware

### 1. ADC platform

The acquisition board is the **Analog Devices EVAL-AD4630-24FMCZ**. It contains an AD4630-24 dual-channel, simultaneous-sampling, 24-bit successive-approximation-register (SAR) ADC.

The converter is rated for sample rates up to 2 million samples per second (MSPS) per channel. The deployed system operates at 500 thousand samples per second (kSPS) per channel. At this operating rate, the Nyquist frequency is 250 kHz.

The evaluation board also contains the ADA4945-1 fully differential amplifier. This amplifier forms the AFE between the external signal and the ADC inputs. Its gain network and feedback components affect the measured bandwidth of the system.

### 2. Embedded controller

The evaluation board connects to a **Digilent ZedBoard** through the field-programmable gate array (FPGA) Mezzanine Card (FMC) connector. The ZedBoard is built around a Xilinx Zynq-7020 system-on-chip (SoC), which combines:

- field-programmable gate array (FPGA) programmable logic
- dual Arm Cortex-A9 processor cores
- external Double Data Rate 3 synchronous dynamic random-access memory (DDR3)
- Ethernet, Universal Serial Bus (USB), and serial communication interfaces

The programmable logic receives the ADC data stream. The Arm processor runs embedded Linux and provides the software environment used to configure the ADC, start captures, and store the acquired data.

This project uses the prebuilt Analog Devices Kuiper Linux image, Industrial Input/Output (IIO) drivers, device tree, and hardware description language (HDL) design supplied for the evaluation platform. No custom FPGA or HDL design is used in this repository.

### 3. Host communication

The ZedBoard connects to a Windows host computer through Gigabit Ethernet.

Two network protocols are used:

- **Secure Shell (SSH)** is used to send commands to the ZedBoard.
- **SSH File Transfer Protocol (SFTP)** is used to transfer completed capture files to the host computer.

A Universal Asynchronous Receiver-Transmitter (UART) serial console is also available through the ZedBoard USB-UART interface. The serial console is mainly used during initial setup and network recovery.

### 4. Analysis environment

The host-side workflow uses both Python and MATLAB.

**Python is used for:**

- SSH connection and command execution
- capture control
- SFTP file transfer
- binary data parsing
- count-to-voltage conversion
- Method B compensation
- MATLAB data-file creation
- quick time-domain and frequency-domain plots

**MATLAB is used for:**

- detailed waveform analysis
- frequency-response validation
- system-identification analysis
- noise-baseline characterization
- burst detection
- burst-quality scoring
- field-data review

This division was selected because Python provides a lightweight interface to the hardware, while MATLAB is convenient for detailed signal processing and engineering analysis.

## External anti-alias filter

A fourth-order Butterworth Sallen-Key low-pass filter was designed, built, and tested as a possible external anti-alias filter.

The filter had the following measured performance:

- design cutoff frequency: 120 kHz
- measured -3 dB frequency: approximately 116.5 kHz
- measured passband flatness: approximately ±0.17 dB

The filter works as designed, but it is not included in the deployed signal chain.

During system validation, the ADA4945-1 front end on the evaluation board was found to begin rolling off at approximately 48 to 53 kHz in the tested configuration. This is below the external filter cutoff and well below the 250 kHz Nyquist frequency at the 500 kSPS operating rate. The tested source also carries little energy in the higher-frequency region where aliasing would be a concern.

For this specific sensor and front-end combination, the external filter was therefore kept as an optional stage rather than added to the deployed hardware.

This decision is specific to the tested measurement chain. It should not be interpreted as a general statement that external anti-alias filtering is unnecessary. A different sensor, preamplifier, source, or sample rate may require additional analog filtering. The combined frequency response of every analog stage before the ADC must be considered.

Digital compensation can correct measured attenuation within the usable band, but it cannot remove aliasing after sampling. Once an out-of-band component has folded into the sampled frequency range, it cannot be separated from a real in-band component using the sampled data alone.

The external filter is described in [08, AA filter design](08-aa-filter-design.md). The measured AFE rolloff and its digital correction are described in [06, frequency rolloff investigation](06-frequency-rolloff-investigation.md) and [07, digital compensation](07-digital-compensation.md).

## Design goals

### 1. Portability

The system had to operate away from the laboratory using portable power and a laptop host. This required a compact acquisition platform, a practical network connection, and a capture method that did not depend on laboratory instruments during normal field operation.

### 2. High-resolution broadband capture

The system had to measure low-level voltage signals while retaining enough bandwidth for sinusoidal, ultrasonic, and transient measurements. The AD4630-24 provides a nominal resolution of 24 bits, but the effective performance of the complete system also depends on the AFE, reference, power supplies, grounding, cabling, and environmental noise.

For this reason, system performance is reported using measured signal-to-noise ratio (SNR), effective number of bits (ENOB), and shorted-input noise rather than nominal ADC resolution alone.

### 3. Simultaneous two-channel sampling

Both input channels had to be sampled at the same instant. Simultaneous sampling is important when comparing two sensor locations, checking inter-channel timing, or evaluating the relative response of two measurement channels.

The raw binary file therefore stores one sample frame at a time, with one 32-bit word for Channel 0 and one 32-bit word for Channel 1.

### 4. Reliable acquisition

The system records each capture locally on the ZedBoard before transferring it to the host. Network throughput is therefore not part of the real-time sampling path.

The host software checks:

1. whether the remote capture command completed successfully
2. whether the remote file has the expected size
3. whether the transferred file has the same size
4. whether the binary data contains complete sample frames
5. whether the parsed frame count matches the requested sample count

If one of these checks fails, the capture is rejected instead of being saved as valid measurement data.

The capture command is still connected to the SSH session. If the SSH connection is interrupted, the capture may stop. The software treats this as a failed acquisition and does not continue to the normal save path.

### 5. Reduced electrical coupling from the host

Ethernet was selected instead of a permanent USB data connection because the Ethernet physical interface is transformer coupled. This reduces direct conductive coupling and helps prevent a ground loop between the laptop and the DAQ.

This benefit only applies when there is no second conductive connection between the host and the measurement system. The USB-UART cable or another grounded instrument can bypass the Ethernet isolation. These additional connections should therefore be removed during low-noise measurements unless they are required.

### 6. Repeatable calibration

Raw ADC counts do not directly represent voltage. Each channel is calibrated using a multi-point linear fit:

```text
V = GAIN × count + OFFSET
```

Separate gain and offset values are used for Channel 0 and Channel 1. The calibration procedure also reports fit residuals and the coefficient of determination, R², so the linearity of the measured count-to-voltage relationship can be checked.

### 7. Measured frequency-response correction

The frequency response of the AFE was measured rather than assumed. A swept-sine test was used to determine the gain of each channel over the frequency range of interest.

The measured response is used by the Method B regularized frequency-domain compensator. This corrects the measured in-band attenuation while limiting excessive noise amplification at higher frequencies.

### 8. Preservation of raw measurement data

The saved MATLAB data file stores the original raw ADC counts together with the calibration and compensation metadata. Calibrated and compensated signals can then be reconstructed later.

This approach has three advantages:

1. The original hardware output remains available.
2. Derived signals cannot become separated from the parameters used to create them.
3. Previous captures can be processed again if the analysis method is improved.

## Why the architecture looks this way

### Local capture instead of live network streaming

The ZedBoard runs the IIO utility `iio_readdev` locally and writes the data to a binary file. The completed file is transferred to the host only after acquisition has finished.

The capture sequence is:

1. The Python host script opens an SSH connection to the ZedBoard.
2. The requested ADC sample rate is written through the IIO interface.
3. `iio_readdev` starts a finite dual-channel capture.
4. The binary sample stream is written to a local file on the ZedBoard.
5. The host waits for the capture command to complete.
6. The remote file size is checked against the requested sample count.
7. The file is transferred to the host using SFTP.
8. The local file size and sample-frame structure are checked.
9. The raw channel data is parsed and converted to calibrated voltage.
10. The capture and its metadata are saved in a MATLAB `.mat` file.

This arrangement was selected for the following reasons:

- A temporary change in network throughput cannot drop samples during acquisition.
- The expected binary file size can be calculated before transfer.
- Incomplete captures can be detected before analysis.
- The board-side process remains simple.
- Acquisition remains separate from signal processing.

### Ethernet instead of a permanent USB data link

Ethernet carries both the SSH control traffic and the SFTP file transfer. It also provides transformer isolation at the network interface. This is useful in a high-resolution measurement system because direct host grounding can introduce ground-loop current and electrical noise.

The USB-UART connection remains useful for setup and recovery, but it is not required during normal Ethernet-controlled acquisition.

### Python for acquisition and MATLAB for analysis

Python handles the hardware-facing operations because it provides direct support for SSH, SFTP, binary file handling, numerical arrays, and MATLAB-compatible data files.

MATLAB handles the analysis-facing operations because the project requires frequency-domain processing, filtering, system identification, visualization, and burst-quality evaluation.

Both environments implement the same Method B compensation parameters so that the Python quick-look and the MATLAB analysis use the same correction method.

## Measured system characteristics

| Parameter | Measured or configured value |
|---|---|
| ADC platform | Dual-channel, 24-bit, simultaneous sampling |
| Configured input range | Approximately ±5 V differential |
| Operating sample rate | 500 kSPS per channel |
| Maximum ADC capability | 2 MSPS per channel |
| Nyquist frequency at operating rate | 250 kHz |
| Raw sample-frame format | Two 32-bit channel words per frame |
| Raw dual-channel data rate | 4 MB/s |
| Typical uncompressed file size | 80 MB for a 20-second capture |
| Calibration method | Separate multi-point linear fit for each channel |
| Measured SNR | Approximately 103.2 dB |
| Measured ENOB | Approximately 16.9 bits |
| Shorted-input noise | Approximately 20 µV root mean square (RMS) |
| Measured sample-rate stability | Approximately ±40 parts per million (ppm) |

The raw data-rate calculation is:

```text
500,000 sample frames/s × 8 bytes/sample frame = 4,000,000 bytes/s
```

Each sample frame contains one 32-bit word from Channel 0 and one 32-bit word from Channel 1.

The ZedBoard contains 512 MB of DDR3 memory. Using a conservative estimate of approximately 400 MB of available memory gives a capture limit of about 100 seconds at 500 kSPS. This is approximately five times longer than the longest capture used during testing.

## Main engineering finding

During validation, the measured signal amplitude decreased as the input frequency increased. The attenuation became noticeable near 30 kHz, which was lower than expected for the intended measurement bandwidth.

The problem was investigated using swept-sine system identification. The measured response was compared with the evaluation-board schematic, and the dominant rolloff was traced to the ADA4945-1 feedback network on the EVAL-AD4630-24FMCZ.

The response was measured separately for both ADC channels. The measured magnitude response was then used to build a regularized frequency-domain compensator.

This work established:

1. the actual frequency response of the tested acquisition path
2. the usable uncompensated bandwidth
3. the frequency range over which digital correction could be applied
4. separate correction data for Channel 0 and Channel 1
5. a repeatable method for reconstructing corrected signals from raw captures

The result is a DAQ system whose measured AFE response is known and included in the analysis. The correction is based on the measured hardware response rather than only on nominal component values.

The investigation is documented in [06, frequency rolloff investigation](06-frequency-rolloff-investigation.md). The compensation method is documented in [07, digital compensation](07-digital-compensation.md).

## Current system state

The following parts of the project have been completed and tested:

1. ZedBoard and AD4630 evaluation-board setup
2. embedded Linux and IIO device bring-up
3. local dual-channel binary capture
4. SSH control and SFTP file transfer over Ethernet
5. remote and local capture-size validation
6. separate count-to-voltage calibration for each channel
7. analog front-end system identification
8. Method B compensation in Python and MATLAB
9. shorted-input noise and system-performance validation
10. external anti-alias filter design and bench testing
11. MATLAB noise-baseline characterization
12. MATLAB burst detection and quality scoring

The external anti-alias filter remains available as a tested optional stage but is not part of the deployed signal chain.

## Acronym reference

| Acronym | Meaning |
|---|---|
| ADC | Analog-to-digital converter |
| AFE | Analog front end |
| DAQ | Data acquisition |
| DC | Direct current |
| DDR3 | Double Data Rate 3 Synchronous Dynamic Random-Access Memory |
| ENOB | Effective number of bits |
| FMC | FPGA Mezzanine Card |
| FPGA | Field-programmable gate array |
| HDL | Hardware description language |
| IIO | Industrial Input/Output |
| kSPS | Thousand samples per second |
| MSPS | Million samples per second |
| RMS | Root mean square |
| SAR | Successive approximation register |
| SFTP | SSH File Transfer Protocol |
| SNR | Signal-to-noise ratio |
| SoC | System-on-chip |
| SSH | Secure Shell |
| UART | Universal Asynchronous Receiver-Transmitter |
| USB | Universal Serial Bus |

## How to read the rest of the repository

1. [02, hardware architecture](02-hardware-architecture.md) describes the signal chain, component selection, and power arrangement.
2. [03, ZedBoard and ADC setup](03-zedboard-adc-setup.md) covers jumper settings, mechanical assembly, network setup, and IIO checks.
3. [04, data capture workflow](04-data-capture-workflow.md) explains local capture, file transfer, binary parsing, and the saved data format.
4. [05, calibration and voltage conversion](05-calibration-and-voltage-conversion.md) describes the per-channel count-to-voltage calibration and measured noise performance.
5. [06, frequency rolloff investigation](06-frequency-rolloff-investigation.md) documents the measured bandwidth limitation and its hardware cause.
6. [07, digital compensation](07-digital-compensation.md) describes the regularized frequency-domain correction.
7. [08, AA filter design](08-aa-filter-design.md) documents the external fourth-order Butterworth filter.
8. [09, field deployment and usage](09-field-deployment-and-usage.md) gives the field setup, operating procedure, and troubleshooting steps.
9. [10, burst-quality pipeline](10-burst-quality-pipeline.md) describes noise-baseline characterization, burst detection, quality metrics, and operator decisions.
