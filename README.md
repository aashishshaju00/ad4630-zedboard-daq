# 24-bit High Speed Portable Acoustic DAQ - Build & Validation

End-to-end design, build, and validation of a portable **24-bit, dual-channel, 500 kSPS data acquisition system** for broadband acoustic / ultrasonic measurement, built around the Analog Devices AD4630-24 and a Zynq-7000 (ZedBoard) embedded controller.

This repo is an engineering build record. It documents the whole chain — signal-chain architecture, analog front-end characterization, calibration, a measurement-driven digital compensator, and a near-real-time capture + quality-assessment pipeline — with the reasoning behind the decisions, not just the final settings.

| Measured | |
|---|---|
| Resolution | 24-bit, dual-channel simultaneous |
| Sample rate | 500 kSPS/ch (validated; converter capable of 2 MSPS) |
| SNR | 103.2 dB (10 M-sample capture) |
| ENOB | 16.9 bits |
| Noise floor | ~19.9 µV RMS, shorted input |
| Sample-rate stability | ±40 ppm |

**What this project touches:** mixed-signal signal-chain design · analog front-end characterization · DSP (non-parametric Wiener deconvolution, minimum-phase reconstruction) · near-real-time DAQ · Python host tooling · embedded Linux / IIO · MATLAB analysis · calibration & validation methodology.

---

## Signal chain

![Deployed signal chain and power architecture](figures/02-deployed-signal-chain.png)

```
UAE sensor + preamp → ADA4945-1 FDA (AFE, on the AD4630 eval board) → AD4630-24 ADC
    → ZedBoard (Zynq-7020) → Gigabit Ethernet (isolated) → Host PC (Python / MATLAB)
```

The analog source can be any compatible differential-output sensor within the ADC's input range. Note there is **no external anti-alias filter** in the deployed chain — the eval board's front end is already band-limited well below Nyquist, which made one redundant. (One was designed and built anyway; see [docs/08](docs/08-aa-filter-design.md) for that story.)

### Core hardware
- **ADC:** Analog Devices EVAL-AD4630-24FMCZ (24-bit, 2 MSPS-capable SAR)
- **Front end:** ADA4945-1 fully-differential amplifier (on the eval board)
- **Controller:** Digilent ZedBoard (Zynq-7020)
- **Analog power:** LT3045 ultra-low-noise LDO, isolated from the digital rail
- **Host link:** Gigabit Ethernet (galvanic isolation via RJ-45 magnetics)

### Core software
- **Python** — capture orchestration, file transfer, calibration, live quality glance
- **MATLAB** — signal analysis, validation, and the field burst-quality pipeline

---

## Design philosophy

**Robust acquisition.** Capture runs locally on the ZedBoard and is transferred afterward, rather than streamed live — a network hiccup can't drop samples mid-capture.

**Clean measurement environment.** Ethernet over USB, because the network hardware gives galvanic isolation for free, keeping the host out of the analog noise floor.

**Separation of capture and analysis.** Python keeps hardware control lightweight; MATLAB does the heavy analysis. The *same* compensation math runs on both sides.

**Characterize before correcting.** The front-end behavior was measured and modeled before any digital correction was applied, so the compensator is built on the system's real measured response — not on assumptions.

**Raw counts are the source of truth.** Captures save only the raw ADC counts plus metadata; calibrated and compensated signals are recomputed downstream. Smaller files, nothing can drift out of sync, and every old capture can be re-derived if the method improves.

---

## Documentation

| Section | What's in it |
|---|---|
| [01  System Overview](docs/01-system-overview.md) | High-level architecture and design goals |
| [02  Hardware Architecture](docs/02-hardware-architecture.md) | Signal chain, component choices, power isolation |
| [03  ZedBoard + ADC Setup](docs/03-zedboard-adc-setup.md) | Embedded Linux / IIO bring-up, jumpers, static IP, iiod |
| [04  Data Capture Workflow](docs/04-data-capture-workflow.md) | Capture, transfer, and the raw-counts save format |
| [05  Calibration & Noise](docs/05-calibration-and-voltage-conversion.md) | Counts-to-volts calibration and the measured noise floor |
| [06  Frequency Rolloff Investigation](docs/06-frequency-rolloff-investigation.md) | Debug case study: finding the front-end rolloff |
| [07  Digital Compensation](docs/07-digital-compensation.md) | Measurement-driven Wiener / minimum-phase correction |
| [08  Anti-Alias Filter Design](docs/08-aa-filter-design.md) | The filter that was designed but not deployed |
| [09  Deployment & Usage](docs/09-field-deployment-and-usage.md) | Field setup, run workflow, troubleshooting |
| [10  Burst-Quality Pipeline](docs/10-burst-quality-pipeline.md) | Per-strike detection, scoring, and GOOD/BAD verdicts |
| [Interactive UART diagnostics](https://aashishshaju00.github.io/ad4630-zedboard-daq/docs/ZedBoard_DAQ_SOP.html) | USB-UART checks for network recovery, IIO status, local capture testing, shutdown, and staged recovery |
---

## Repository structure

```
ad4630-zedboard-daq/
├── README.md
├── LICENSE
├── requirements.txt
├── docs/                     # 01–10 build documentation
├── scripts/
│   ├── start_daq_uae.py              # main capture + Method B compensation + quick-look
│   ├── acquisition_io.py             # shared failure-safe capture / transfer / parse module
│   ├── calibrate_dual.py             # per-channel multi-point DC calibration (differential)
│   ├── calibrate_single.py           # single-channel DC calibration, one at a time (bench)
│   ├── freq_sweep_sysid_dual.py      # swept-sine front-end characterization (per channel)
│   ├── shutdown_zedboard.py          # clean ping-confirmed remote halt
│   ├── sysid_analysis_dual.m         # sweep → Bode + model fit + Wiener params (MATLAB)
│   ├── characterize_noise_baseline.m # site noise-floor characterization (MATLAB)
│   └── daq_burst_quality.m           # burst detection + quality scoring (MATLAB)
├── tests/                    # unit tests for the capture module (Python unittest)
├── figures/                  # validation and architecture figures
├── data/
├── hardware/
└── references/
```

The MATLAB analysis pipeline (noise-baseline characterization + burst-quality assessment) is documented in [doc 10](docs/10-burst-quality-pipeline.md).

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/start_daq_uae.py` | Drives a capture over SSH, pulls it back, calibrates, applies Method B compensation, and shows a dual-channel quick-look. Saves raw counts + metadata to `.mat`. |
| `scripts/acquisition_io.py` | Shared module (imported, not run directly): failure-safe remote capture with timeout handling, SFTP pull with size verification, dual-channel binary parse, and retry/cleanup helpers used by the capture and sweep scripts. |
| `scripts/calibrate_dual.py` | Steps through DC levels and fits `V = GAIN·count + OFFSET` per channel, with R² / residual reporting and an inter-channel offset check. |
| `scripts/calibrate_single.py` | Multi-point DC calibration for one channel at a time (single-ended bench wiring: IN+ driven, IN− grounded). Same `V = GAIN·count + OFFSET` fit as the dual version. |
| `scripts/freq_sweep_sysid_dual.py` | Swept-sine system identification of the analog front end, run once per channel; saves per-channel sweep `.mat` files. |
| `scripts/shutdown_zedboard.py` | Issues a remote `poweroff` and confirms halt by ping (a halted board can't report that it's halted). |
| `scripts/sysid_analysis_dual.m` | Turns a channel sweep into a Bode magnitude, fits 1-/2-pole models (AICc-selected), and recommends Wiener compensator parameters. |
| `scripts/characterize_noise_baseline.m` | Establishes the per-site noise floor (robust STE/line-length statistics) used as the detection reference. |
| `scripts/daq_burst_quality.m` | Detects impact bursts, scores each on SNR / decay R² / ring-down τ / PSD correlation / impact energy, and assigns GOOD/MARGINAL/BAD/SATURATED verdicts. |

> Config lives in a `USER CONFIG` block at the top of each script (IP, paths, calibration). The SSH password is the stock ADI Kuiper default - change it on your own board.

---

This repository documents how the system was built and *why* the key decisions were made, so another engineer could understand, reproduce, or extend it.
