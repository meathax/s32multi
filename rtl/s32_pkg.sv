//============================================================================
//  Sega System 32 / Multi 32 for MiSTer
//  Common package: board descriptor, SDRAM region map, shared types
//  Reference: docs/DESIGN.md §3.4, §4.2, §9.3
//============================================================================

package s32_pkg;

    // ------------------------------------------------------------------
    // SDRAM region bases (byte addresses) — DESIGN.md §4.2
    // ------------------------------------------------------------------
    localparam [26:0] SDR_MAINCPU_BASE    = 27'h000_0000; // 2 MB
    localparam [26:0] SDR_SOUNDCPU_BASE   = 27'h020_0000; // 4 MB
    localparam [26:0] SDR_TILES_BASE      = 27'h060_0000; // 4 MB
    localparam [26:0] SDR_MULTIPCM_BASE   = 27'h0A0_0000; // 4 MB
    localparam [26:0] SDR_MCU_BASE        = 27'h0E0_0000; // V25 ROM (64 KiB)
    localparam [26:0] SDR_SPARE_BASE     = SDR_MCU_BASE; // remainder of 2 MB slot
    localparam [26:0] SDR_SPRITES_BASE    = 27'h100_0000; // 16 MB

    // ------------------------------------------------------------------
    // Board descriptor (first 64 bytes of ioctl stream) — DESIGN.md §3.4
    // ------------------------------------------------------------------
    typedef struct packed {
        logic       multi32;       // V70 dual-screen board
        logic       has_v25;       // protection MCU present
        logic       v25_table;     // 0=ga2 table, 1=arf table
        logic       has_adc;       // MSM6253 analog board
        logic       has_track;     // uPD4701 trackball board
        logic       has_ppi;       // i8255 4/6-player board
        logic       has_dsp_hle;   // arescue math DSP HLE
        logic       has_cd_stub;   // kokoroj SCSI/CXD stubs
        logic       dual_pcb;      // arescue/f1en bridge responder
        logic [6:0] prot_sel;      // HLE protection select (PROT_*)
        // Sprite ROMs contain one, two, or four 4 MiB banks.  MAME mirrors
        // the controller's 2-bit bank selection modulo that physical count.
        // Old all-zero descriptors have no valid field and retain four banks.
        logic       sprite_bank_valid;
        logic [1:0] sprite_bank_mask; // 0/1/3 for 4/8/16 MiB respectively
        logic       flip_y;         // cabinet/game orientation (holo)
        logic       gun_aim;        // positional-gun analog default-invert (alien3/jpark)
        logic       coin_swap;      // Alien3 swaps Coin1/Coin2 service bits
        logic       orunners;       // OutRunners two-station digital/analog wiring
    } board_desc_t;

    // HLE protection selects (prot_sel)
    localparam [6:0] PROT_NONE     = 7'd0;
    localparam [6:0] PROT_SONIC    = 7'd1;  // rev C level loader
    localparam [6:0] PROT_BRIVAL   = 7'd2;
    localparam [6:0] PROT_DARKEDGE = 7'd3;
    localparam [6:0] PROT_F1LAP    = 7'd4;
    localparam [6:0] PROT_DBZVRVS  = 7'd5;
    localparam [6:0] PROT_JLEAGUE  = 7'd6;

    // ------------------------------------------------------------------
    // V60 interrupt sources — DESIGN.md §5.5
    // ------------------------------------------------------------------
    localparam int MAIN_IRQ_VBSTART = 0;
    localparam int MAIN_IRQ_VBSTOP  = 1;
    localparam int MAIN_IRQ_SOUND   = 2;
    localparam int MAIN_IRQ_TIMER0  = 3;
    localparam int MAIN_IRQ_TIMER1  = 4;

    // Z80 sound interrupt sources — DESIGN.md §7.2
    localparam int SOUND_IRQ_YM3438 = 0;
    localparam int SOUND_IRQ_V60    = 1;

endpackage
