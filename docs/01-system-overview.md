# System Overview

## Purpose

This project documents a portable 24-bit data acquisition system built for high-resolution broadband analog signal capture. The system is designed to bridge the gap between benchtop measurement capability and field-deployable operation by combining precision data conversion, local embedded capture, Ethernet-based host transfer, calibrated voltage reconstruction, and post-processing support in both Python and MATLAB.

Although the system has been exercised on broadband acoustic and ultrasonic measurements, the architecture is not limited to a single sensing modality. The build is intended more generally as a portable differential-input DAQ platform for applications that require:

- high dynamic range
- simultaneous sampling
- broadband capture
- reliable host communication
- reproducible calibration
- traceable validation of analog front-end behavior

## What the System Does

At a high level, the system accepts an analog differential input, digitizes it using a 24-bit simultaneous-sampling converter platform, stores the captured data locally on an embedded processing platform, transfers the recorded data to a host computer over Ethernet, and then reconstructs calibrated voltage waveforms for analysis.

The system was designed around the idea that acquisition and analysis should be treated as two separate layers:

- the **acquisition layer** should prioritize robustness, continuity, and hardware reliability
- the **analysis layer** should prioritize calibration, visualization, validation, and flexibility

This separation is one of the main architectural choices in the project and drives much of the software and interface design.

## Full Signal Chain

The present signal chain is:

**Differential analog source**  
→ **EVAL-AD4630-24FMCZ acquisition board** (ADA4945-1 front end, itself band-limited)  
→ **ZedBoard (Zynq-7020)**  
→ **local binary capture on embedded Linux**  
→ **Ethernet transfer to host PC**  
→ **Python and MATLAB post-processing**

In this architecture, the analog source can be any compatible differential-output sensor or front-end stage within the allowable input range of the ADC path. The current implementation has primarily been validated using broadband time-varying signals, including sinusoidal sweeps, square waves, and impulsive measurements.

## Core Hardware Elements

### ADC platform
The acquisition core is based on the **Analog Devices EVAL-AD4630-24FMCZ**, which provides high-resolution simultaneous sampling and a well-supported reference design path for FPGA-based acquisition.

### Embedded controller
The ADC evaluation board interfaces to a **Digilent ZedBoard** built around the **Xilinx Zynq-7020**. This provides both programmable logic support and an embedded Linux environment for acquisition control.

### Host communication
The embedded platform communicates with a Windows host computer over **Gigabit Ethernet**. This link is used for command execution, file transfer, and workflow control.

### Analysis environment
The host-side workflow uses:
- **Python** for orchestration, remote execution, file transfer, and quick visualization
- **MATLAB** for calibrated waveform analysis, validation, and further signal-processing work

### Why there's no external anti-alias filter
I designed a dedicated 4th-order Butterworth Sallen-Key anti-alias filter from scratch (120 kHz corner), built it, and bench-characterized it — ±0.17 dB passband flatness, 116.5 kHz measured −3 dB point. It works. It just isn't in the signal chain, because the AD4630 eval board's own front end (the ADA4945-1 amplifier) already rolls off from around 48–53 kHz — well below my filter's 120 kHz corner. With the front end already band-limited that far down, and Nyquist at 250 kHz, a separate analog AA stage in front of it wouldn't have changed anything. The full design and measured response are still documented in [08 — AA Filter Design](08-aa-filter-design.md). The flip side — that same rolloff also attenuates the real signal I care about — is the subject of [06](06-frequency-rolloff-investigation.md) and [07](07-digital-compensation.md).

## Design Goals

The build was driven by a small set of engineering goals.

### 1. Portability
The system needed to move away from a purely bench-tethered workflow and toward a portable DAQ architecture that can operate from battery-powered hardware and a laptop host.

### 2. High-resolution broadband acquisition
The system needed to preserve fine voltage resolution while still supporting broadband transient and sinusoidal measurements over a wide useful frequency range.

### 3. Reliable capture
The acquisition path needed to prioritize continuity and robustness over convenience. For that reason, local embedded capture was preferred over real-time streamed acquisition to the host.

### 4. Clean host isolation
The host interface needed to minimize measurement contamination from shared grounds and noisy direct tethering. Ethernet was preferred because it naturally supports galvanic isolation through standard network hardware.

### 5. Reproducible calibration and correction
The build needed a workflow that could convert raw counts into calibrated voltages and also handle known analog front-end limitations using a measured and validated correction method.

## Why the Architecture Looks This Way

### Local capture instead of live streaming
One of the key design decisions in this project was to capture data locally on the ZedBoard rather than stream data continuously over the network in real time.

The local-capture approach provides several advantages:
- lower risk of sample drops caused by network timing issues
- simpler acquisition-side logic
- better repeatability during larger captures
- easier separation between capture and analysis

In practice, the workflow is:
1. execute acquisition locally on the embedded platform
2. save the result as a binary capture file
3. transfer the file to the host
4. perform conversion and analysis on the host

### Ethernet instead of USB
The host connection uses Ethernet rather than direct USB tethering. This was chosen mainly for measurement robustness. Ethernet hardware typically includes transformer isolation, which helps reduce unwanted coupling between the DAQ hardware and the host PC.

For precision analog capture, this is a practical system-level advantage rather than just a convenience feature.

### Python for control, MATLAB for analysis
Python and MATLAB serve different roles in the workflow.

Python is used where it is strongest in this build:
- remote command execution
- file movement
- capture automation
- data packaging
- lightweight visualization

MATLAB is used where it adds the most value:
- calibrated waveform interpretation
- time-frequency inspection
- validation plots
- downstream signal-processing continuity

This split was intentional and helps keep each part of the workflow focused.

## Measured System Characteristics

At the current stage of development, the platform has demonstrated the following measured or established characteristics:

- **ADC resolution:** 24-bit converter platform
- **input range:** ±5 V differential
- **sample rate:** configurable up to 2 MSPS; operated and validated at 500 kSPS per channel
- **channels:** 2 simultaneous channels available
- **interface:** embedded local capture with Ethernet transfer
- **buffer capacity:** 512 MB DDR3 on ZedBoard, supporting 170+ seconds of continuous capture at 500 kSPS
- **calibrated count-to-voltage conversion:** established through multi-point DC calibration
- **measured ENOB:** approximately 16.9 bits
- **measured SNR:** approximately 103.2 dB
- **broadband noise floor:** approximately 20 µV RMS

These values reflect the present measured system state and are documented in more detail in later sections of the repository.

## Important Engineering Finding

A major part of the build process was not just getting the system to run, but understanding how the analog front end actually behaved under test.

During validation, the measured response showed amplitude rolloff at higher frequencies. This was traced to the analog front-end network on the evaluation board and later quantified using frequency sweep testing and fitted system identification. That diagnosis led to the implementation of a frequency-domain compensation method that corrects the measured front-end response without introducing startup transients or phase distortion.

This was a key turning point in the project because it changed the system from a nominally working DAQ chain into a characterized and corrected measurement platform.

The full investigation is documented in:
- [06 — Frequency Rolloff Investigation](06-frequency-rolloff-investigation.md)
- [07 — Digital Compensation](07-digital-compensation.md)

## Current System State

At the time of writing, the following parts of the system are already working:

- ZedBoard and AD4630 platform bring-up
- local binary capture workflow
- Ethernet-based host transfer
- count-to-voltage calibration
- custom anti-alias filter designed, built, and characterized (kept as a spare — not in the deployed chain)
- analog front-end system identification
- frequency-domain compensation in Python
- frequency-domain compensation in MATLAB

The following work is in progress:

- integrated validation with the AA filter installed in the full signal chain
- expansion of documentation, figures, and build records

## How to Read the Rest of the Repository

This document introduces the full DAQ architecture. The remaining documentation breaks the build into more focused topics:

- [02 — Hardware Architecture](02-hardware-architecture.md) explains the hardware stack and signal-chain components
- [03 — ZedBoard + ADC Setup](03-zedboard-adc-setup.md) covers the ZedBoard and ADC platform bring-up
- [04 — Data Capture Workflow](04-data-capture-workflow.md) explains the acquisition and host-transfer flow
- [05 — Calibration and Voltage Conversion](05-calibration-and-voltage-conversion.md) covers calibration and scaling
- [06 — Frequency Rolloff Investigation](06-frequency-rolloff-investigation.md) documents the measured bandwidth limitation
- [07 — Digital Compensation](07-digital-compensation.md) explains the compensation method and implementation details
- [08 — AA Filter Design](08-aa-filter-design.md) documents the external anti-alias filter design
- [09 — Field Deployment and Usage](09-field-deployment-and-usage.md) covers the end-to-end operating workflow
