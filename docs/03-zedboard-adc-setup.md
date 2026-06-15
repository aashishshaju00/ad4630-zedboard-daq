# ZedBoard and ADC setup

This document describes the initial setup of the Digilent ZedBoard and the Analog Devices EVAL-AD4630-24FMCZ evaluation board. It covers jumper settings, board revision checks, mechanical assembly, embedded Linux startup, network configuration, and basic Industrial Input/Output (IIO) checks.

This procedure should be completed before using the automated [data capture workflow](04-data-capture-workflow.md).

The jumper and power checks are important. An incorrect adjustable input/output voltage (VADJ) setting can damage the evaluation board. Complete the setup with power disconnected and verify each item before applying 12 V to the ZedBoard.

## Setup sequence

Use the following order:

1. Record the evaluation-board hardware revision.
2. Set the ZedBoard boot-mode jumpers.
3. Set VADJ to 2.5 V.
4. Insert the Kuiper Secure Digital (SD) card.
5. Install the evaluation board on the FPGA Mezzanine Card (FMC) connector.
6. Connect the serial console and Ethernet.
7. Apply 12 V power.
8. Confirm that embedded Linux boots.
9. Configure the network address.
10. Confirm that the IIO device is available.
11. Run a short capture test.

## 1. Record the evaluation-board revision

The EVAL-AD4630-24FMCZ exists in more than one hardware revision. Known versions include the older Revision C and the current Revision E.

The revisions are not identical. Differences include:

- voltage-reference components
- amplifier supply rails
- connector numbering
- schematic component designators
- board-layout details

For example:

- Revision C uses an LTC6655 voltage reference.
- Revision E uses an ADR4550 voltage reference.
- Revision C uses input SubMiniature version A (SMA) connectors J2 to J5.
- Revision E uses input SMA connectors J1 to J4.

Before assembly:

1. Find the revision marking printed on the evaluation board.
2. Record the revision and date code in the project notes.
3. Use the schematic and user guide that match that revision.
4. Confirm the input connector labels before connecting a signal source.

This prevents a connector number or component designator from one revision being applied incorrectly to another revision.

## 2. Set the ZedBoard boot-mode jumpers

The ZedBoard must be configured to boot from the SD card.

Set boot-mode jumpers JP7 to JP11 as follows:

| Jumper | Required position |
|---|---|
| JP7 | GND |
| JP8 | GND |
| JP9 | 3V3 |
| JP10 | 3V3 |
| JP11 | GND |

`GND` means ground, and `3V3` means the 3.3 V logic rail.

JP6 controls the processing-system multiplexed input/output pin 0 (PS_MIO0) pull-down. JP6 must also be shorted for SD-card boot.

Check the physical jumper positions against the ZedBoard reference documentation. Do not rely only on a previous setup, since jumpers may have been moved for another project.

## 3. Set the FMC adjustable voltage

Set **VADJ jumper J18 to 2.5 V**.

VADJ sets the input/output bank voltage used by the FMC interface. The ZedBoard default is 1.8 V, while the EVAL-AD4630-24FMCZ requires the 2.5 V setting used by this platform.

An incorrect VADJ setting can expose the evaluation board interface to the wrong voltage. For this reason:

1. Disconnect ZedBoard power.
2. Locate J18.
3. Confirm the jumper is in the 2.5 V position.
4. Check the position a second time before installing or powering the evaluation board.

This is the most important electrical configuration check in the initial assembly.

## 4. USB jumper note

JP2 and JP3 configure the Universal Serial Bus On-The-Go (USB-OTG) interface on connector J13. They control USB bus-voltage and operating-mode behavior.

These jumpers are not required for the USB to Universal Asynchronous Receiver-Transmitter (USB-UART) serial console on J14. J14 is powered through its own USB connection.

The USB-UART connection is used for:

- the first login
- network setup
- checking Linux startup messages
- recovering the board if Ethernet is misconfigured

## 5. Mechanical assembly

Complete the following steps with all power disconnected.

1. Insert the Analog Devices Kuiper SD card into the J12 slot on the underside of the ZedBoard.

   The evaluation kit includes an EVAL-SD-KUIPERZ card containing the Linux, IIO, device-tree, and hardware description language (HDL) configuration used by this platform. No custom field-programmable gate array (FPGA) build is required for this project.

2. Inspect the FMC connectors on the ZedBoard and evaluation board.

   Check for bent pins, foreign material, or mechanical damage before joining the boards.

3. Align the evaluation-board FMC connector with the ZedBoard J1 low-pin-count FMC (FMC-LPC) connector.

4. Press the boards together evenly until the connector is fully seated.

   The connector should engage without excessive force. If it does not align easily, remove the board and check the connector position rather than forcing it.

5. Confirm that the evaluation board is mechanically supported and not loading the FMC connector at an angle.

6. Connect the required signal cables while the system is still unpowered.

7. Recheck:

   - SD card installed
   - FMC connector fully seated
   - VADJ set to 2.5 V
   - boot jumpers set for SD-card boot
   - signal connections correct

The evaluation board is powered through the FMC connector. It does not use a separate external power cable.

## 6. First boot

Use the following connections for the initial startup:

```text
12 V supply
    → ZedBoard J20 barrel connector

Host USB port
    → ZedBoard J14 USB-UART connector

Host Ethernet port
    → ZedBoard J10 Ethernet connector
```

Then:

1. Apply 12 V to the ZedBoard J20 barrel connector.
2. Switch on the ZedBoard.
3. Allow approximately 30 seconds for Linux to boot.
4. Open a serial terminal on the host computer.
5. Configure the serial terminal for `115200 8N1`.

`115200 8N1` means:

- 115200 bits per second
- 8 data bits
- no parity
- 1 stop bit

Light-emitting diode (LED) behavior can vary with the Kuiper image version. Use the serial console, network response, and IIO checks as the main confirmation that the board has booted correctly.

## 7. Serial login

Log in through the USB-UART console using the credentials for the installed Kuiper image.

The stock image used during this project uses:

```text
username: analog
password: analog
```

The host capture scripts connect over Secure Shell (SSH) using:

```text
username: root
password: analog
```

These are vendor-default credentials. Change them before field deployment or connection to an untrusted network.

The Python scripts obtain the password from:

1. the `ZED_PASS` environment variable, when it is set
2. the stock fallback value in the script, when the environment variable is not set

The `ZED_USER` and `ZED_PASS` configuration values must match the account configured on the ZedBoard.

## 8. Configure a static Ethernet address

The project uses the following ZedBoard Internet Protocol (IP) address:

```text
192.168.1.100
```

On the Kuiper image used for this project, the static address can be configured by editing `/etc/network/interfaces`:

```text
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
```

Restart networking after saving the file:

```bash
sudo systemctl restart networking
```

The exact network-management method can vary between Kuiper image versions. If `/etc/network/interfaces` does not control `eth0`, identify the active network manager before changing additional configuration files.

For a direct Ethernet connection, configure the host computer with an address on the same subnet, for example:

```text
Host:      192.168.1.10
ZedBoard:  192.168.1.100
Netmask:   255.255.255.0
```

The USB-UART console is the recovery path if the static Ethernet configuration prevents network access.

## 9. Confirm the IIO daemon

The IIO daemon, `iiod`, exposes IIO devices over the network.

Check its status on the ZedBoard:

```bash
systemctl status iiod
```

The expected state is:

```text
active (running)
```

The daemon listens on port `30431`.

In this project, `iiod` is used for bring-up and diagnostic commands such as `iio_info`. The normal acquisition script does not stream the measurement through the network IIO connection. Instead, it runs `iio_readdev` locally on the ZedBoard and transfers the completed binary file using SSH File Transfer Protocol (SFTP).

This distinction matters because the Ethernet transfer is not part of the real-time sample path.

## 10. Configure the host computer

Install the IIO software tools on the host computer.

For Windows:

- install the Analog Devices `libiio` Microsoft Installer package

For Linux:

- install `libiio-utils`
- install `pyadi-iio` if the Python IIO interface is required

Confirm that the host can reach the ZedBoard:

```bash
ping 192.168.1.100
```

Then query the IIO context:

```bash
iio_info -u ip:192.168.1.100
```

The output should include:

- the `ad4630-24` IIO device
- the `sampling_frequency` attribute
- both buffered voltage channels

If `iio_info` connects to the board but `ad4630-24` is missing, check:

1. whether the Kuiper image loaded the correct FPGA configuration
2. whether the correct device tree was loaded
3. whether the SD card is seated correctly
4. whether the evaluation board is fully seated in the FMC connector
5. whether VADJ is set to 2.5 V

Power-cycle the system after correcting the hardware or boot configuration.

## 11. IIO device and sample layout

The downstream capture workflow uses one IIO device:

```text
ad4630-24
```

The project configuration has the following operating assumptions:

- the `sampling_frequency` attribute controls the ADC sample rate
- the operating sample rate is set to `500000` samples per second
- both ADC channels are captured together
- each sample frame contains two little-endian signed 32-bit integer words
- the signed 24-bit ADC result is stored in the upper 24 bits of each word

The host parser therefore performs:

```python
raw = np.fromfile(filepath, dtype="<i4").reshape(-1, 2)
ch0_raw = raw[:, 0] >> 8
ch1_raw = raw[:, 1] >> 8
```

Here:

- `"<i4"` means a little-endian signed four-byte integer
- `reshape(-1, 2)` separates the two channel words in each sample frame
- `>> 8` shifts the signed 24-bit ADC result into the normal integer position

The binary format and parsing procedure are described further in [04, data capture workflow](04-data-capture-workflow.md).

## 12. Short capture test

Run a short remote capture:

```bash
iio_readdev -u ip:192.168.1.100 -b 1000 -s 1000 ad4630-24 > test.bin
```

This command requests:

- an IIO buffer size of 1000 sample frames
- a finite capture of 1000 sample frames
- data from the `ad4630-24` device
- binary output written to `test.bin`

For two 32-bit channel words per sample frame, the expected file size is:

```text
1000 frames × 2 words/frame × 4 bytes/word = 8000 bytes
```

Check that:

1. `test.bin` exists.
2. The file is not empty.
3. The file size is 8000 bytes for the expected two-channel format.
4. No error is reported by `iio_readdev`.

A correctly sized file confirms that the host can reach the IIO device and receive buffered samples. The full capture, transfer, and validation procedure is described in [04, data capture workflow](04-data-capture-workflow.md).

## Setup checklist

Before running the main capture script, confirm:

1. Evaluation-board revision recorded.
2. Boot jumpers configured for SD-card boot.
3. JP6 shorted.
4. VADJ J18 set to 2.5 V.
5. Kuiper SD card installed.
6. Evaluation board fully seated on the FMC connector.
7. ZedBoard boots successfully.
8. Static IP address configured.
9. Host and ZedBoard are on the same subnet.
10. `iiod` is running.
11. `iio_info` lists `ad4630-24`.
12. The short capture produces the expected file size.

Once these checks pass, continue with [04, data capture workflow](04-data-capture-workflow.md).

Full procurement, assembly, and deployment information is also available in the [DAQ system build guide](../references/DAQ_System_Build_Guide.pdf).
