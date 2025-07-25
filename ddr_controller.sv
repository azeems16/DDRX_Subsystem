module ddr_controller #(
    parameter ADDR_WIDTH = 17,   // Row + Column (based on JEDEC config)
    parameter BANK_WIDTH = 2,    // Number of bank bits
    parameter BG_WIDTH   = 1,    // Bank group bits (DDR4+)
    parameter RANK_WIDTH = 1,    // Number of chip selects/ranks
    parameter DATA_WIDTH = 64    // DQ bus width (e.g., 64 for x8 DIMM ×8 lanes) (1 rank contains 8 DRAM chips, each with their own x8 lanes (DQ lines); 8x8 = 64)
)(
    input  logic                   dfi_clk,     // Controller clock
    input  logic                   rst_n,       // Active-low async reset

    // === Command/Address Channel (MC → PHY) ===
    output logic [ADDR_WIDTH-1:0] dfi_address,  // Address bus: column for RD/WR, row for ACT
    output logic [BANK_WIDTH-1:0] dfi_bank,     // Bank select within a rank
    output logic [BG_WIDTH-1:0]   dfi_bg,       // Bank group (used in DDR4+)
    output logic [RANK_WIDTH-1:0] dfi_cs_n,     // Active-low chip select — 1-hot encoded per rank
    output logic                  dfi_ras_n,    // Row Address Strobe — low for ACT or REF
    output logic                  dfi_cas_n,    // Column Address Strobe — low for RD/WR
    output logic                  dfi_we_n,     // Write Enable — low for WR, high for RD
    output logic                  dfi_act_n,    // ACTIVATE command strobe (low to assert)
    output logic                  dfi_cke,      // Clock Enable (used for power-down modes)
    output logic                  dfi_odt,      // On-Die Termination control
    output logic                  dfi_reset_n,  // Reset to the DRAM (low = reset)

    // === Write Data Channel (MC → PHY) ===
    output logic [DATA_WIDTH-1:0]   dfi_wrdata,      // Write data to be driven to PHY/DQ
    output logic                    dfi_wrdata_en,   // Write data strobe: pulse to signal valid data
    output logic [RANK_WIDTH-1:0]   dfi_wrdata_cs,   // Rank to which data is being written
    output logic [DATA_WIDTH/8-1:0] dfi_wrdata_mask, // Byte-enable mask (1 = masked/disabled)

    // === Read Data Channel (PHY → MC) ===
    output logic                    dfi_rddata_en,   // Pulse to request read from PHY
    output logic [RANK_WIDTH-1:0]   dfi_rddata_cs,   // Rank from which to read
    input  logic [DATA_WIDTH-1:0]   dfi_rddata,      // Returned read data from PHY
    input  logic                    dfi_rddata_valid, // Signals that dfi_rddata is valid this cycle

    output logic                    dfi_init_start,
    input  logic                    dfi_init_complete,
    // === NEW: Control Inputs ===
    // All cmd_* inputs coming from host
    input  logic                    dfi_init_complete, // Signals PHY is initialized and ready
    input  logic                    cmd_valid,         // Indicates valid command from host/testbench
    input  logic [1:0]              cmd_type,          // 0 = ACT, 1 = WR, 2 = RD, 3 = PRC
    input  logic [RANK_WIDTH-1:0]   cmd_rank,
    input  logic [ADDR_WIDTH-1:0]   cmd_address,       // Row or column
    input  logic [BANK_WIDTH-1:0]   cmd_bank,
    input  logic [BG_WIDTH-1:0]     cmd_bg,
    input  logic [DATA_WIDTH-1:0]   cmd_wrdata,        // Only used for WRITE
    input  logic [DATA_WIDTH/8-1:0] cmd_wrdata_mask,   // Optional byte mask
    input  logic                    mode               // TB Only: 0 = Training, 1 = Mission Mode

    // TODO: add ports to send back to host/testbench for AXI handshake completion
);
// TODO: add functionality for: dfi_reset_n, dfi_odt
// =====================================
// DDR Timing Constraints (in cycles)
// Assumed DDR Clock: 800 MHz (1.25 ns)
// Adjust if your clk freq differs
// =====================================
// tRAS = row active time, minimum time row needs to stay open before PRECHARGE
localparam int tRCD_CYCLES  = 13; // Row to Column Delay (ACTIVATE → READ/WRITE): Sense amplifiers need time to latch data from row, mimimum time needed for us to issue R/W after ACT
localparam int tRP_CYCLES   = 13; // Precharge command to ACTIVATE (same bank): Sense amplifiers need time to reset before new row can activate, minimum time needed for us to issue ACT after PRC
localparam int tRC_CYCLES   = 36; // ACTIVATE to ACTIVATE (same bank): tRC = tRAS + tRP: minimum time row needs to stay open + tRP before  a new ACT (ACT -> PRC -> ACT)
localparam int tRRD_CYCLES  = 6;  // ACTIVATE to ACTIVATE (diff bank group)

localparam int tWRTP_CYCLES = 15; // Write Recovery Time (WRITE → PRECHARGE)
localparam int tRTP_CYCLES  = 7;  // Read to Precharge (READ → PRECHARGE)

localparam int tRFC_CYCLES  = 350; // Refresh Cycle Time (REFRESH → mm_next command)

localparam int tCL_CYCLES = 22;  // how many cycles we wait for before asserting write_en and sending first write beat
localparam int tCWL_CYCLES = 16; // how many cycles we wait for before receiving first read beat

localparam BURST_LENGTH = 8; // Standard default for most DDR3/DDR4 memory systems
localparam DFI_RATIO    = 4; // dfi_clk is 4x slower than DRAM data rate
localparam DFI_BEATS_PER_BURST = BURST_LENGTH/DFI_RATIO;

localparam INIT_DELAY_TARGET = 32;
localparam WRITE_LVL_TRAINING_CYCLES = 64;
localparam READ_LVL_TRAINING_CYCLES = 64;
localparam FAKE_READ_EYE_CENTER = 37;
//=========================================
// FSM: Training and Mission Mode
//=========================================
// TODO: if feasible/practical, add state logic for REFRESH, ZQ_CALIB
typedef enum logic [2:0] {
    IDLE,
    ACTIVATE,
    READ,
    WRITE,
    PRECHARGE
} mm_state_t;
mm_state_t mm_state, mm_next;

typedef enum logic [2:0] {
    IDLE,
    INIT_DELAY,
    WRITE_LVL,
    READ_LVL,
    DONE
} tm_state_t;
tm_state_t tm_state, tm_next;

// Cycle Counters
int init_delay_cycles;

int activate_cycles;
int write_cycles;
int read_cycles;
int precharge_cycles;

// Beat Counter
int wr_beats;
int rd_beats;

logic fake_eye_center;
always_comb begin
    tm_next = tm_state;
    if (!mode) begin    // Training
        case(tm_state) 
            IDLE: begin
                tm_next = INIT_DELAY;
            end

            INIT_DELAY: begin
                if (init_delay_cycles >= INIT_DELAY_TARGET) begin
                    tm_next = WRITE_LVL;
                end
            end

            WRITE_LVL: begin
                if (write_lvl_done) begin
                    tm_next = READ_LVL;
                end
            end

            READ_LVL: begin
                if (read_lvl_done && fake_eye_center) begin
                    tm_next = DONE;
                end
            end

            DONE: begin
                tm_next = IDLE;
            end
        endcase
    end
end

always_comb begin
    mm_next = mm_state;
    if (mode) begin     // Mission Mode
        case(mm_state)
            IDLE: begin
                if (cmd_valid && cmd_type == 2'b00 && dfi_init_complete) begin
                    mm_next = ACTIVATE;
                end
                else begin
                    mm_next = IDLE;
                end
            end

            ACTIVATE: begin
                if (activate_cycles >= tRCD_CYCLES) begin
                    if (cmd_type == 2'b01) begin
                        mm_next = WRITE;
                    end
                    else if (cmd_type == 2'b10) begin
                        mm_next = READ;
                    end
                end
            end

            WRITE: begin
                if (wr_beats >= DFI_BEATS_PER_BURST && write_cycles >= tWRTP_CYCLES) begin
                    mm_next = PRECHARGE;
                end
                else begin
                    mm_next = WRITE;
                end
            end

            READ: begin
                if (rd_beats >= DFI_BEATS_PER_BURST && read_cycles >= tRTP_CYCLES) begin
                    mm_next = PRECHARGE;
                end
                else begin
                    mm_next = READ;
                end
            end

            PRECHARGE: begin
                if (precharge_cycles >= tRP_CYCLES) begin
                    mm_next = IDLE;
                end
                else begin
                    mm_next = PRECHARGE;
                end
            end
            default: begin
                $display("[FSM]: Invalid state detected! Resetting to IDLE.");
                mm_next = IDLE;
            end
        endcase
    end
end

always_ff @ (posedge dfi_clk) begin
    if (!rst_n) begin
        mm_state <= IDLE;
        tm_state <= IDLE;
    end
    else begin
        mm_state <= mm_next;
        tm_state <= tm_next;
    end
end

//=========================================
// FSM: Training and Mission Mode
//=========================================

//=========================================
// DDR CONTROLLER LOGIC: START
//=========================================

task reset_cycle_counters();
    activate_cycles   <= 0;
    write_cycles      <= 0;
    read_cycles       <= 0;
    precharge_cycles  <= 0;
endtask

task reset_beat_counters();
    wr_beats         <= 0;
    rd_beats         <= 0;
endtask

task reset_act_drivers();
    dfi_address <= '0;
    dfi_bank    <= '0;
    dfi_bg      <= '0;
    dfi_cs_n    <= '1;
    dfi_ras_n   <=  1;
    dfi_cas_n   <=  1;
    dfi_we_n    <=  1; 
    dfi_act_n   <=  1;
    dfi_cke     <=  0;
endtask

task reset_wr_drivers();
    dfi_wrdata      <= '0;
    dfi_wrdata_en   <=  0;
    dfi_wrdata_cs   <= '1;
    dfi_wrdata_mask <= '0;
endtask

task reset_rd_drivers();
    dfi_rddata_en <=  0;
    dfi_rddata_cs <= '1;
endtask

task reset();
    reset_cycle_counters();
    reset_act_drivers();
    reset_wr_drivers();
    reset_rd_drivers();
    reset_beat_counters();
endtask

task activate_cmd();
    dfi_act_n   <= ~(activate_cycles == 0);
    dfi_ras_n   <= 0;   
    dfi_cas_n   <= 1;
    dfi_we_n    <= 1;
endtask

task read_cmd();
    dfi_ras_n <= 1;
    dfi_cas_n <= 0;
    dfi_we_n  <= 1;
endtask

task write_cmd();
    dfi_ras_n <= 1;
    dfi_cas_n <= 0;
    dfi_we_n  <= 1;

    dfi_rddata_en <= 0;
endtask

task precharge_cmd();
    dfi_act_n <= 1;
    dfi_ras_n <= 0;
    dfi_cas_n <= 1;
    dfi_we_n  <= 0;
endtask

logic [DATA_WIDTH-1:0] rd_queue[$]; // Queue of 64 bit values, dynamically sized

always_ff @ (posedge dfi_clk) begin
    if (!rst_n) begin
        reset();
    end
    else begin
        if (mode) begin
            case (mm_state)
                IDLE: begin
                    reset();
                end

                ACTIVATE: begin
                    dfi_cs_n        <= cmd_rank; // Assumes cmd_rank is 1-hot.
                    dfi_cke         <= 1;
                    activate_cmd();
                    dfi_address     <= cmd_address;
                    dfi_bank        <= cmd_bank;
                    dfi_bg          <= cmd_bg;

                    activate_cycles <= activate_cycles + 1;
                end

                WRITE: begin
                    write_cmd();
                    if (write_cycles >= tCWL_CYCLES) begin
                        dfi_wrdata_en   <= 1;
                        dfi_wrdata_cs   <= dfi_cs_n;
                        dfi_wrdata_mask <= cmd_wrdata_mask;

                        dfi_wrdata   <= cmd_wrdata;
                        wr_beats     <= wr_beats + 1;
                    end
                    write_cycles <= write_cycles + 1;
                end

                READ: begin
                    read_cmd();
                    dfi_rddata_en <= 1;
                    dfi_rddata_cs <= dfi_cs_n;
                    if (dfi_rddata_valid && read_cycles >= tCL_CYCLES) begin
                        rd_queue.push_back(dfi_rddata);
                        rd_beats      <= rd_beats + 1;
                    end
                    read_cycles   <= read_cycles + 1;
                end

                PRECHARGE: begin
                    precharge_cmd();
                    reset_beat_counters();
                    dfi_wrdata_en    <= 0;
                    dfi_rddata_en    <= 0;

                    precharge_cycles <= precharge_cycles + 1;
                end
            endcase
        end
    end
end

task reset_training();
    init_delay_cycles <= 0;
    write_lvl_cycles  <= 0;
    read_lvl_cycles   <= 0;
    write_lvl_done    <= 0;
    read_lvl_done     <= 0;
endtask

always_ff @ (posedge dfi_clk) begin
    if (!rst_n) begin
        reset_training();
    end
    else begin
        if(!mode) begin
            case(tm_state)
                IDLE: begin
                    reset_training();
                    dfi_init_start <= (tm_state == IDLE && tm_next == INIT_DELAY);
                end

                INIT_DELAY: begin
                    init_delay_cycles <= init_delay_cycles + 1;
                end

                WRITE_LVL: begin
                    if (write_lvl_cycles <= WRITE_LVL_TRAINING_CYCLES) begin
                        dfi_wrdata_en   <= (write_lvl_cycles % 4 == 0); // Send strobe to PHY once every 4 cycles to sample
                        dfi_wrdata_cs   <= '0;                          // Target rank 0
                        dfi_wrdata      <= 64'hAAAA_AAAA_AAAA_AAAA;     // Optional toggling pattern
                        dfi_wrdata_mask <= '0;                          // No mask during training

                        write_lvl_cycles <= write_lvl_cycles + 1;
                    end
                    else begin
                        dfi_wrdata_en   <= 0;
                        write_lvl_cycles <= 0;
                        write_lvl_done   <= 1;
                    end
                end

                READ_LVL: begin
                    if (read_lvl_cycles == FAKE_READ_EYE_CENTER) begin
                        $display("[READ_LVL] Eye center detected — strobe aligned after %0d cycles", read_lvl_cycles);
                        dfi_rddata_en   <= 0;
                        read_lvl_done   <= 1;
                        read_lvl_cycles <= 0;
                        fake_eye_center <= 1;
                    end
                    else if (read_lvl_cycles >= READ_LVL_TRAINING_CYCLES) begin
                        $display("Read leveling: Training timeout.");
                        dfi_rddata_en   <= 0;
                        read_lvl_done   <= 1;
                        read_lvl_cycles <= 0;
                        fake_eye_center <= 0;
                    end
                    else begin
                        dfi_rddata_en   <= (read_lvl_cycles % 4 == 0);
                        dfi_rddata_cs   <= '0;
                        read_lvl_cycles <= read_lvl_cycles + 1;
                    end
                end

                DONE: begin
                    reset_training();
                end
            endcase
        end
    end
end

assign dfi_reset_n = 1;                      // Assume DRAM already initialized
assign dfi_odt     = (mm_state == WRITE);     // Enable termination during writes

endmodule