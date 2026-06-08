# ZedBoard + ADC Setup

This is the embedded bring-up: how the AD4630 eval board and the ZedBoard are configured, booted, and put on the network so the host can talk to them. Get the jumpers wrong here and you can damage the ADC board, so this one is worth doing slowly. It's the platform the [capture workflow](04-data-capture-workflow.md) sits on top of.

## Jumpers first — before any power

Two jumper groups matter, and one of them is destructive if set wrong.

**Boot mode (JP7–JP11)** — configured for SD-card boot:

| Jumper | Position |
|---|---|
| JP7 | GND |
| JP8 | GND |
| JP9 | 3V3 |
| JP10 | 3V3 |
| JP11 | GND |

**VADJ (J18) — set to 2.5 V.** This sets the FMC I/O bank voltage that the eval board interfaces to. The EVAL-AD4630-24FMCZ needs 2.5 V I/O; setting this wrong will damage the ADC board the moment power is applied. Check it twice. Also install the USB power jumpers (JP2, JP3) so the console works during setup.

## Mechanical assembly

With power disconnected:

1. Insert the Kuiper Linux SD card into the J12 slot on the underside of the ZedBoard. The EVAL-AD4630-24FMCZ kit ships with a pre-configured card (EVAL-SD-KUIPERZ) carrying the full Linux + IIO + HDL stack, so there's no custom FPGA work to do.
2. Align the eval board's FMC connector with the ZedBoard's J1 FMC-LPC connector and press until fully seated — it should engage smoothly without forcing. The ADC board draws all its power through the FMC connector; no separate supply.
3. Don't connect 12 V until every signal connection is made and checked.

## First boot and network

1. 12 V to the ZedBoard barrel jack (J20). Wait ~30 s for boot — the LD0 LED blinks once Linux is up.
2. Open a serial console on the host (115200 8N1) over the USB-UART on J14. Log in with the Kuiper default `analog` / `analog`.
3. Give the board a static IP by editing `/etc/network/interfaces`:

```
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
```

Then `sudo systemctl restart networking`.

4. Confirm the IIO daemon is up — it's what exposes the ADC over the network:

```
systemctl status iiod      # expect: active (running)
```

`iiod` listens on port **30431**. The serial console is also the recovery path: if Ethernet is misconfigured, this is how you fix the IP and check `iiod` without the network.

> Credentials note: the serial console and the stock image use `analog`/`analog`. The capture scripts in this repo connect over **SSH** using the `root` account (also password `analog` on the stock Kuiper image) — change `ZED_USER`/`ZED_PASS` in the script config block to match your board.

## Host side

Install **libiio** on the host (the Windows MSI is on the Analog Devices libiio releases page; on Linux it's `libiio-utils` + `pyadi-iio`). Verify the toolchain reaches the board:

```
iio_info -u ip:192.168.1.100
```

This should enumerate the `ad4630-24` device, its `sampling_frequency` attribute, and its buffer capability. If it connects but the device is missing, the FPGA bitstream probably didn't load — power-cycle, reseat the SD card, and re-check that VADJ is 2.5 V.

## The IIO device

Everything downstream talks to one device, `ad4630-24`:

- **Sample rate** is set through the `sampling_frequency` attribute (500000 for this system).
- **Two channels**, simultaneously sampled.
- **Sample layout:** each sample is two `int32` words (one per channel), with the signed 24-bit differential result in the top 24 bits — so a capture file is parsed as `reshape(-1, 2)` then `>> 8` (see [04](04-data-capture-workflow.md)).

A one-line capture sanity check straight from the command line:

```
iio_readdev -u ip:192.168.1.100 -b 1000 ad4630-24 > test.bin
```

If that produces a non-empty file, the platform is up and the [capture workflow](04-data-capture-workflow.md) will run. Full procurement-to-field detail is in the [build guide](../references/).
