DDR Controller (DFI Interface) — Project Overview
This project implements a simplified behavioral DDR memory controller that communicates with a DFI-compliant PHY. It is designed for simulation and learning purposes, supporting both training sequences (e.g. write leveling and read eye detection) and real transaction sequences (e.g. activate → read/write → precharge).

Key Features
Supports both Training Mode (PHY calibration) and Mission Mode (host-driven memory transactions)

Implements standard DDR timing constraints: tRCD, tRP, tWRTP, tRTP, etc.

Issues ACT, READ, WRITE, and PRECHARGE commands using JEDEC-style control logic

Models DFI-level signals for command, address, write, and read channels

Parameterized to support different DRAM configurations (banks, bank groups, ranks, data width)

Functional Summary
In Training Mode (mode = 0):
The controller sends periodic write strobes for write leveling, and read strobes to simulate read eye center detection using a mocked alignment point.

In Mission Mode (mode = 1):
The controller responds to external cmd_* inputs, sequencing ACTIVATE, READ, WRITE, and PRECHARGE with correct delays and beat tracking (DFI burst length = 8, DFI ratio = 4).

Internally, the design uses:

Separate FSMs for training and mission modes

Beat counters for read/write data

Cycle counters to track timing margins

Simple command decoding and signal driving logic

Future Updates
- Add testbench to simulate host commands and validate controller response
- Integrate wave-level verification with timing assertions
- Abstract out PHY into a separate model (eventually replace with real DRAM behavioral models)
- Add AXI-to-DDR bridge logic to support real SoC-style integration
- Support refresh, ZQ calibration, and power-down/self-refresh modes
- Expand rank support and add out-of-order scheduling