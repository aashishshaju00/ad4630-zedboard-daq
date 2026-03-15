# High-Speed Portable Data Acquisition System Build and Validation

This repository documents the design, integration, calibration, and validation of a portable **24-bit high-speed data acquisition system** built around the Analog Devices AD4630 platform and a Zynq-based embedded controller.

The goal of the project was to build a **reliable, research-grade DAQ platform** capable of capturing high-resolution broadband analog signals while remaining portable and suitable for field or experimental environments. The repository focuses on the **engineering decisions, system architecture, validation process, and supporting software** used to build the system.

Rather than presenting only the final working setup, this repository documents the **complete build process**, including hardware integration, acquisition workflow design, calibration, characterization of analog front-end behavior, and signal reconstruction methods.

---

# Project Objective

The objective of this build was to create a portable and practical DAQ platform capable of:

- high-resolution broadband signal acquisition  
- portable battery-powered operation  
- reliable capture without data loss  
- calibrated voltage reconstruction from raw ADC counts  
- characterization and correction of analog front-end limitations  
- seamless integration with common analysis environments  

The system was designed as a **general-purpose research data acquisition platform** that can be used with a wide range of analog sensors and signal sources.

---

# System Architecture

**Signal chain**
```
Analog Differential Input → [Anti Alias Filter] → EVAL-AD4630-24FMCZ → ZedBoard (Zynq-7020)
                                                                      │
                                                           Gigabit Ethernet
                                                          (galvanic isolation)
                                                                      │
                                                               Windows Laptop
                                                             Python (capture)
                                                             MATLAB (analysis)
```

### Core hardware

- **ADC platform:** Analog Devices EVAL-AD4630-24FMCZ  
- **Embedded controller:** Digilent ZedBoard (Zynq-7020)  
- **Interface:** Gigabit Ethernet communication  
- **Power concept:** portable system with isolated analog and digital domains  

### Core software

- **Python:** hardware communication, capture orchestration, file transfer  
- **MATLAB:** signal visualization, analysis, and validation  

---

# Design Philosophy

Several guiding principles shaped the architecture of the system.

### Robust acquisition
Data capture is performed locally on the embedded platform instead of being streamed directly to the host computer. This reduces the risk of dropped samples and keeps the acquisition layer simple and reliable.

### Clean measurement environment
Ethernet was chosen instead of USB because it naturally provides galvanic isolation through network hardware. This helps reduce unwanted coupling between the host computer and the analog measurement chain.

### Separation of capture and analysis
The acquisition workflow is handled by Python, while signal interpretation and analysis are performed in MATLAB. This keeps hardware control lightweight while preserving a flexible analysis environment.

### Characterize before correcting
During validation, the analog front-end behavior was measured and modeled before implementing any digital correction. This ensured that signal reconstruction methods were based on measured system behavior rather than assumptions.

---

# Key System Capabilities

- 24-bit simultaneous sampling data acquisition  
- configurable sample rates up to **2 MSPS**  
- differential analog input support  
- embedded local capture using Linux + IIO framework  
- Ethernet-based host communication  
- calibrated voltage reconstruction  
- validated broadband measurement performance  

---

# Repository Structure
```
ad4630-zedboard-daq/
├── README.md
├── docs/
│   ├── 01-system-overview.md
│   ├── 02-hardware-architecture.md
│   ├── 03-zedboard-adc-setup.md
│   ├── 04-data-capture-workflow.md
│   ├── 05-calibration-and-voltage-conversion.md
│   ├── 06-frequency-rolloff-investigation.md
│   ├── 07-digital-compensation.md
│   ├── 08-aa-filter-design.md
│   └── 09-field-deployment-and-usage.md
├── scripts/
│   ├── start_daq.py
│   ├── calibrate.py
│   ├── freq_sweep_sysid.py
│   └── time_freq_plot.m
├── data/
│   └── sysid_results.json
├── figures/
├── hardware/
└── references/
```
---

# Workflow Overview

1. Configure and boot the ZedBoard + ADC platform  
2. Capture raw data locally on the embedded system  
3. Transfer the recorded file to the host computer  
4. Convert raw ADC counts to calibrated voltages  
5. Apply system-response correction if required  
6. Inspect signals in time and frequency domains  

---

# Documentation Roadmap

Detailed documentation of the system is provided in the `docs/` directory.

| Section | Description |
|------|------|
| [01 — System Overview](docs/01-system-overview.md) | High-level architecture and design goals |
| [02 — Hardware Architecture](docs/02-hardware-architecture.md) | Physical system layout and signal chain |
| [03 — ZedBoard + ADC Setup](docs/03-zedboard-adc-setup.md) | Embedded system setup and configuration |
| [04 — Data Capture Workflow](docs/04-data-capture-workflow.md) | Acquisition workflow and host transfer |
| [05 — Calibration](docs/05-calibration-and-voltage-conversion.md) | Voltage scaling and noise characterization |
| [06 — Frequency Response Investigation](docs/06-frequency-rolloff-investigation.md) | Measurement and modeling of analog front-end behavior |
| [07 — Digital Compensation](docs/07-digital-compensation.md) | Frequency-response correction approach |
| [08 — Anti-Alias Filter Design](docs/08-aa-filter-design.md) | External analog conditioning stage |
| [09 — Deployment and Usage](docs/09-field-deployment-and-usage.md) | Practical operating workflow |

---

# Included Scripts

| Script | Purpose |
|------|------|
| `scripts/start_daq.py` | Main Python acquisition workflow |
| `scripts/calibrate.py` | Voltage calibration utility |
| `scripts/freq_sweep_sysid.py` | Frequency response characterization |
| `scripts/time_freq_plot.m` | MATLAB signal visualization |

---

# Current Project Status

**Completed**

- hardware bring-up of the ZedBoard + AD4630 platform  
- embedded local capture workflow  
- host transfer and analysis pipeline  
- calibrated voltage conversion  
- analog front-end characterization  
- system-response correction methods  

**In progress**

- external anti-alias filter integration  
- additional validation measurements  
- expansion of documentation and figures  

---

# Purpose of This Repository

This repository serves as an **engineering build record** for the system.  
It documents the hardware architecture, acquisition workflow, validation steps, and software tools required to reproduce and operate the DAQ platform.

The documentation focuses on explaining **how the system was built and why key design decisions were made**, so that other engineers can understand, reproduce, or extend the platform.
