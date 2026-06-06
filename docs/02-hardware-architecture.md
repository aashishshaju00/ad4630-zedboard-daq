# Hardware Architecture

This document covers the physical signal chain, the reasoning behind the component choices, and the two-rail power scheme that protects the 24-bit noise floor. It is the hardware companion to the [System Overview](01-system-overview.md).

## Signal Chain

![Deployed signal chain and power architecture](../figures/02-deployed-signal-chain.png)

The deployed chain runs from the sensor to the host in five stages:

1. **Sensor + preamp.** A UAE sensor (broadband ultrasonic acoustic-emission) and its preamplifier produce a balanced, line-level signal.
2. **Analog front end (AFE).** On the AD4630 evaluation board, an ADA4945-1 fully-differential amplifier (FDA) takes the single-ended input, converts it to the differential pair the ADC needs, and drives the converter. The FDA's feedback network also imposes its own low-pass rolloff, which matters later.
3. **ADC.** The AD4630-24, a 24-bit dual-channel simultaneous-sampling SAR converter, run at 500 kSPS per channel.
4. **Embedded controller.** A Xilinx Zynq-7000 on a Digilent ZedBoard captures the converter stream into DDR3 under embedded Linux, using the Industrial I/O (IIO) framework.
5. **Host.** Sample data crosses galvanically isolated Gigabit Ethernet to a laptop, where Python runs the capture and MATLAB does the analysis.

One detail matters for the rest of the build: the ADA4945-1 FDA sits on the eval board, between the input and the converter, so its behavior is part of every measurement. It becomes the focus of the [rolloff investigation](06-frequency-rolloff-investigation.md).

## Why there's no external anti-alias filter

I designed a 4th-order Butterworth Sallen-Key anti-alias filter from scratch (120 kHz corner), built it, and bench-characterized it: ±0.17 dB passband flatness and a 116.5 kHz measured −3 dB point. It works. I left it out of the signal chain anyway, and that was the right call.

The reason is the eval board's own front end. The ADA4945-1 already has a low-pass built into its feedback network, rolling off from roughly 48–53 kHz (it shifts a little with wiring), well below the filter's 120 kHz corner. An anti-alias filter only helps if its corner sits below whatever follows it, and here the front end is already band-limited much lower, so an external filter ahead of it would do nothing. At 500 kSPS the Nyquist limit is 250 kHz, the front end is well into its rolloff long before that, and the source carries little energy up there anyway. A separate analog AA stage is redundant.

The same rolloff also attenuates the 30–120 kHz band of interest, which is a problem solved in software (see the [rolloff investigation](06-frequency-rolloff-investigation.md) and the [digital compensation](07-digital-compensation.md)). So that one rolloff plays two roles: it is the effect being compensated for, and it is the reason no external filter is needed. The filter design is documented in [08 — AA Filter Design](08-aa-filter-design.md), because designing and validating it was part of the work.

## Component Selection and Rationale

Each stage was chosen against datasheet specifications rather than convenience, because at 24 bits the weakest component sets the floor for the whole chain.

| Stage | Selection | Rationale |
|-------|-----------|-----------|
| Sensor | UAE sensor + preamp | flat broadband response, low self-noise, balanced output drive |
| Anti-aliasing | 4th-order Butterworth (own design) | Sallen-Key in an LM4562NA dual op-amp, 120 kHz corner; designed and characterized, but **not in the deployed chain** (see above) |
| ADC | AD4630-24 | 24-bit, 2 MSPS-capable SAR; run at 500 kSPS dual-channel simultaneous sampling for two-sensor capture |
| FPGA / SoC | Xilinx Zynq-7000 (ZedBoard) | ARM Cortex-A9 + programmable logic; supports IIO / `iiod` for ADC streaming to the host without writing custom drivers |
| Analog power | LT3045 ultra-low-noise LDO | 0.8 µVrms output noise, >75 dB PSRR into the MHz range; holds the 24-bit floor and is isolated from the digital rails |
| Host link | Gigabit Ethernet (Cat6) | RJ-45 magnetics give 1500–2500 Vrms galvanic isolation, which removes the ground loops that otherwise defeat 24-bit precision |

The AD4630-24 can run at 2 MSPS, but the system is operated and validated at **500 kSPS per channel** (250 kHz Nyquist). That covers the band of interest while keeping the Ethernet data rate manageable.

## Power Architecture

![Two isolated power rails](../figures/02-power-architecture.png)

The single biggest factor protecting resolution is keeping the analog and digital sides on **two galvanically isolated power rails**.

**Digital domain (loud, fast switching).** A 12 V LiFePO₄ battery feeds the ZedBoard through its J20 power header. The on-board DC-DC converters supply the Zynq SoC, the programmable logic, and the Ethernet PHY. This side is full of nanosecond-scale switching.

**Analog domain (quiet, sub-µV floor).** A separate 12 V cell feeds an LT3045 ultra-low-noise LDO, producing a clean 5 V rail for the preamp and sensor. The LT3045's 0.8 µVrms noise and high PSRR keep this rail well under the converter's own noise floor.

### Why this matters

A 24-bit converter's noise floor sits at the microvolt level. If the analog and digital sides share a ground or a power return, that nanosecond switching couples straight in and shows up as measured analog noise, eating into the dynamic range the converter was chosen for. Isolating the power rails, together with the transformer isolation already in the Ethernet link, is the cheapest fix and the one that holds up in the field where the grounding can't be controlled.

The payoff is quantified in [05 — Calibration and Noise](05-calibration-and-voltage-conversion.md): a shorted-input RMS noise of roughly 20 µV, a measured SNR of 103.2 dB, and an effective resolution of 16.9 bits.