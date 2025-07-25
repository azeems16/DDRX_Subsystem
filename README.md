# DDRX Subsystem — Behavioral DDR Controller (DFI Interface)

This project implements a simplified behavioral DDR memory controller that communicates with a DFI-compliant PHY. It models both training sequences (used for PHY calibration) and mission-mode transactions (used during normal operation), following JEDEC timing and interface guidelines.

## Current Functionality

- **DFI-Compliant Command/Address Interface**  
  Drives signals such as `dfi_address`, `dfi_act_n`, `dfi_ras_n`, `dfi_cas_n`, and others to simulate real-world DDR control.

- **Training Mode**  
  Includes:
  - `WRITE_LEVELING`: Pulses `dfi_wrdata_en` periodically for PHY DQS alignment
  - `READ_LEVELING`: Sends periodic `dfi_rddata_en` and detects a mock "eye center"

- **Mission Mode**  
  FSM-based sequence handling:
  - ACTIVATE → READ/WRITE → PRECHARGE
  - Handles command timing (`tRCD`, `tCL`, `tCWL`, `tRP`, etc.)
  - Tracks read/write beats using `BURST_LENGTH` and `DFI_RATIO`

- **Resettable Driver Tasks**  
  Modular reset and command tasks for better testbench control and FSM clarity.

## Parameters

| Parameter      | Description                             |
|----------------|-----------------------------------------|
| `ADDR_WIDTH`   | Combined row/column address width       |
| `BANK_WIDTH`   | Bank selection bits                     |
| `BG_WIDTH`     | Bank group bits (DDR4+)                 |
| `RANK_WIDTH`   | Rank/chip select bits                   |
| `DATA_WIDTH`   | DQ bus width (typically 64)             |

## Future Updates

- Add testbench to verify FSMs and DFI signal timing
- Create waveform-based validation and logs
- Abstract PHY behavior to model delay/strobe logic
- Support AXI-to-DDR bridge (for SoC use)
- Add Refresh (`tRFC`) and ZQ Calibration support
- Support for ECC, multiple ranks, and bank interleaving
- Integrate with open-source DRAM models (e.g., Micron)

## File List

- `ddr_controller.sv` – Main behavioral DDR controller module
- `README.md` – Project overview and progress

---

