// ============================================================================
// tf_hdmi_top.v - TF/SD card -> frame buffer -> HDMI (Anlogic EG4S20BG256).
//
// Data flow:
//   SD card (SPI) -> sd_card_top -> sd_loader -> framebuffer (write, 50 MHz)
//   framebuffer (read, 25 MHz) -> vga_disp -> HDMI video/audio core -> TMDS
//
// The SD card carries 640x480 BC1 HXIMAGE3 images in 512-sector slots.
// KEY2 cycles through them, embeds a short stereo cue in HDMI, and reloads it.
// A banked frame buffer supports bilinear scaling to the 640x480 HDMI frame.
//
// Clocks (clk_wize PLL, 50 MHz in):
//   pixel_clk_5x = 125 MHz (TMDS serializer)
//   pixel_clk    =  25 MHz (640x480@60)
// ============================================================================

module tf_hdmi_top (
    input  wire        sys_clk,     // 50 MHz oscillator (R7)
    input  wire        sys_rst_n,   // KEY1 (A2): photo reset / video pause-resume
    input  wire        key_switch,  // KEY2 (B2), active-low: next image
    input  wire        key_previous,// KEY3 (B1), active-low: previous image/video
    input  wire        sw1,         // SW1 (C8) DIP: up="1" show scope, down="0" hide
    input  wire        sw2,         // SW2 (C7): video mode
    input  wire        sw3,         // SW3 (C6): brightness settings, KEY2+/KEY3-
    input  wire        sw4,         // SW4 (C5): photo autoplay / video loop
    input  wire        key_replay,  // KEY4 (C1), active-low: replay current video
    input  wire        SD_MISO,     // (B14)
    output wire        SD_nCS,      // (A12)
    output wire        SD_DCLK,     // (A14)
    output wire        SD_MOSI,     // (A13)
    output wire        HDMI_CLK_P,  // (C3)  connector 1
    output wire        HDMI_D2_P,   // (E1)  D2 = red
    output wire        HDMI_D1_P,   // (F1)  D1 = green
    output wire        HDMI_D0_P,   // (G5)  D0 = blue
    output wire        HDMI_CLK_P1, // (K1)  connector 2 (same signal, fanned out)
    output wire        HDMI_D2_P1,  // (B3)
    output wire        HDMI_D1_P1,  // (E3)
    output wire        HDMI_D0_P1,  // (F5)
    output wire [1:0]  LED          // (A4, A3) common-anode -> active-low
);

    wire sys50;
    EG_LOGIC_BUFG u_system_clock(.i(sys_clk),.o(sys50));
    // ---- clocks -------------------------------------------------------------
    wire pixel_clk_5x;   // 125 MHz
    wire pixel_clk;      // 25 MHz
    wire key_press;
    wire replay_press;
    wire previous_press, pause_press;
    wire nav_next,nav_previous,settings_mode;
    wire [3:0] brightness_gray;
    wire video_mode;
    reg test_mode = 1'b0;
    reg hdmi_vblank;
    wire load_done,photo_load_done_raw;
    wire memory_word_ready,memory_sector_ready,memory_stored,memory_initialized,memory_error;
    wire photo_format_raw;
    assign load_done=photo_load_done_raw&&memory_stored&&!memory_error;
    // KEY1 remains a reset in photo/test mode; in video mode it is a UI key.
    wire reset_key_n = sys_rst_n || (video_mode && !test_mode);
    reg core_rst_n = 1'b0;
    ui_controls u_ui_controls(.clk(sys50),.rst_n(core_rst_n),.sw3(sw3),
        .next_press(key_press),.previous_press(previous_press),
        .settings(settings_mode),.level_gray(brightness_gray),
        .nav_next(nav_next),.nav_previous(nav_previous));
    reg [1:0] sw4_meta;
    reg loop_enable;
    reg [18:0] loop_debounce;
    always @(posedge sys50 or negedge core_rst_n) begin
        if(!core_rst_n) begin sw4_meta<=0;loop_enable<=0;loop_debounce<=0;end
        else begin
            sw4_meta<={sw4_meta[0],sw4};
            if(sw4_meta[1]==loop_enable) loop_debounce<=0;
            else if(loop_debounce==19'd499999) begin
                loop_enable<=sw4_meta[1];loop_debounce<=0;
            end else loop_debounce<=loop_debounce+1'b1;
        end
    end
    wire [9:0] hdmi_cx, hdmi_cy;

    clk_wize u_clk_wize (
        .refclk   (sys_clk),
        .reset    (1'b0),
        .clk0_out (pixel_clk_5x),
        .clk1_out (pixel_clk)
    );

    // Hold reset for about 21 ms after configuration/photo-mode KEY1.
    // The PLL stays running while resets are released in each clock domain.
    reg [19:0] startup_count = 20'd0;
    always @(posedge sys50 or negedge reset_key_n) begin
        if (!reset_key_n) begin
            startup_count <= 20'd0;
            core_rst_n <= 1'b0;
        end else if (!core_rst_n) begin
            startup_count <= startup_count + 1'b1;
            if (&startup_count) core_rst_n <= 1'b1;
        end
    end
    reg [1:0] pixel_reset_sync = 2'b00;
    always @(posedge pixel_clk or negedge core_rst_n) begin
        if (!core_rst_n) pixel_reset_sync <= 2'b00;
        else pixel_reset_sync <= {pixel_reset_sync[0], 1'b1};
    end
    wire pixel_rst_n = pixel_reset_sync[1];

    reg [1:0] sw2_meta;
    reg video_mode_reg;
    assign video_mode=video_mode_reg;
    reg video_paused;
    reg [18:0] mode_debounce;
    reg [3:0] mode_reset;
    reg [4:0] video_slot;
    wire video_stopped;
    wire video_we,video_swap_request;
    wire [9:0] video_seconds_gray;
    wire media_rst_n;
    reg [27:0] video_stall_count;
    reg [9:0] watchdog_seconds;
    reg watchdog_swap;
    // Use the same complete SD/SDRAM/player reset as KEY4. Never reset only
    // the player while a sector or an SDRAM burst is in flight.
    wire video_auto_replay=loop_enable&&!video_paused&&(mode_reset==0)&&
        (video_stopped||(video_stall_count==28'd249999999));
    always @(posedge sys50 or negedge core_rst_n) begin
        if(!core_rst_n) begin
            video_stall_count<=0;watchdog_seconds<=0;watchdog_swap<=0;
        end else begin
            watchdog_seconds<=video_seconds_gray;watchdog_swap<=video_swap_request;
            if(!media_rst_n||!loop_enable||video_paused||video_we||
               (watchdog_seconds!=video_seconds_gray)||
               (watchdog_swap!=video_swap_request)) video_stall_count<=0;
            else if(video_stall_count!=28'd249999999)
                video_stall_count<=video_stall_count+1'b1;
        end
    end
    always @(posedge sys50 or negedge core_rst_n) begin
        if(!core_rst_n) begin
            sw2_meta<=0;video_mode_reg<=0;mode_debounce<=0;mode_reset<=0;video_slot<=0;
            video_paused<=0;
        end else begin
            sw2_meta<={sw2_meta[0],sw2};
            if(mode_reset!=0) mode_reset<=mode_reset-1'b1;
            if(sw2_meta[1]!=video_mode) begin
                if(mode_debounce==19'd499999) begin
                    video_mode_reg<=sw2_meta[1];mode_debounce<=0;mode_reset<=15;video_slot<=0;
                    video_paused<=0;
                end else mode_debounce<=mode_debounce+1'b1;
            end else mode_debounce<=0;
            if(video_mode&&nav_next) begin
                video_slot<=video_slot+1'b1;mode_reset<=15;video_paused<=0;
            end else if(video_mode&&nav_previous) begin
                video_slot<=video_slot-1'b1;mode_reset<=15;video_paused<=0;
            end else if(video_mode&&(replay_press||video_auto_replay)) begin mode_reset<=15;video_paused<=0;end
            else if(video_mode&&(mode_reset==0)&&pause_press) video_paused<=~video_paused;
        end
    end
    assign media_rst_n=core_rst_n&&video_mode&&(mode_reset==0)&&!test_mode;
    wire photo_rst_n=core_rst_n&&!video_mode&&(mode_reset==0)&&!test_mode;
    wire [32:0] card_sectors;
    wire photo_sd_read, video_sd_read;
    wire [31:0] photo_sd_addr, video_sd_addr;

    // Hold KEY2 while releasing KEY1 to enter the card-independent video test.
    reg [1:0] boot_key_sync = 2'b11;
    always @(posedge sys50 or negedge reset_key_n) begin
        if (!reset_key_n) begin
            boot_key_sync <= 2'b11;
            test_mode <= 1'b0;
        end else begin
            boot_key_sync <= {boot_key_sync[0], key_switch};
            if (!core_rst_n) test_mode <= ~boot_key_sync[1];
        end
    end

    // ---- SD controller (active-high reset) ----------------------------------
    wire        sd_init_done;
    wire        sd_rx_error;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;

    sd_card_top #(.SPI_HIGH_SPEED_DIV(23)) u_sd (
        .clk                    (sys50),
        .rst                    (~core_rst_n || (mode_reset!=0)),
        .video_speed            (video_mode),
        .card_sectors           (card_sectors),
        .SD_nCS                 (SD_nCS),
        .SD_DCLK                (SD_DCLK),
        .SD_MOSI                (SD_MOSI),
        .SD_MISO                (SD_MISO),
        .sd_init_done           (sd_init_done),
        .sd_read_error          (sd_rx_error),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );
    assign sd_sec_read=video_mode ? video_sd_read : photo_sd_read;
    assign sd_sec_read_addr=video_mode ? video_sd_addr : photo_sd_addr;

    // ---- key (image switch) debounce + image selection ----------------------
    wire        load_req;
    wire        load_ack;
    wire [31:0] base_sector;
    wire        switch_event;

    key_debounce u_key_debounce (
        .clk       (sys50),
        .rst_n     (core_rst_n),
        .key       (key_switch),
        .key_press (key_press)
    );
    key_debounce u_replay_debounce (
        .clk(sys50),.rst_n(core_rst_n),.key(key_replay),.key_press(replay_press)
    );
    key_debounce u_previous_debounce (
        .clk(sys50),.rst_n(core_rst_n),.key(key_previous),.key_press(previous_press)
    );
    key_debounce u_pause_debounce (
        .clk(sys50),.rst_n(core_rst_n),.key(sys_rst_n),.key_press(pause_press)
    );
    wire photo_next,photo_previous;
    wire [9:0] photo_offset;
    wire photo_front,photo_write_bank,photo_valid;
    reg [1:0] photo_effect,photo_effect_active;
    reg [1:0] effect_meta,effect_sync,effect_previous,effect_pix;
    reg [1:0] effect_choice_meta,effect_choice_sync,effect_choice_previous,effect_choice_pix;
    // KEY4 selects the NEXT transition; an in-flight transition keeps its type.
    always @(posedge sys50 or negedge photo_rst_n) begin
        if(!photo_rst_n) begin photo_effect<=0;photo_effect_active<=0;end
        else begin
            if(replay_press) photo_effect<=(photo_effect==2)?0:photo_effect+1'b1;
            if(photo_next||photo_previous) photo_effect_active<=photo_effect;
        end
    end
    reg [9:0] photo_offset_meta,photo_offset_sync,photo_offset_pix;
    reg [1:0] photo_front_sync;
    reg photo_front_pix;
    photo_slide u_slide (
        .clk(sys50),.rst_n(photo_rst_n),.vblank(hdmi_vblank),
        .loaded(load_done),.next_press(nav_next),.previous_press(nav_previous),
        .next_load(photo_next),.previous_load(photo_previous),.offset(photo_offset),
        .front(photo_front),.write_bank(photo_write_bank),.valid(photo_valid),
        .auto_enable(loop_enable&&!settings_mode)
    );

    image_controller u_image_controller (
        .clk          (sys50),
        .rst_n        (photo_rst_n),
        .sd_init_done (sd_init_done && !test_mode),
        .key_press    (photo_next),
        .previous_press(photo_previous),
        .load_ack     (load_ack),
        .load_req     (load_req),
        .base_sector  (base_sector),
        .switch_event (switch_event)
    );

    (* keep = "true" *) wire audio_clk;
    wire audio_clk_raw;
    reg [31:0] audio_sample_word;
    wire [31:0] beep_sample_word;
    wire sample_tick;
    wire signed [15:0] video_pcm;
    // Launch on the opposite 50 MHz edge to meet the real audio capture hold
    // requirement without relaxing SYS_CLK -> AUDIO_SAMPLE timing constraints.
    always @(negedge sys50 or negedge core_rst_n) begin
        if(!core_rst_n) audio_sample_word<=0;
        else audio_sample_word<=video_mode ? {video_pcm,video_pcm} : beep_sample_word;
    end
    EG_LOGIC_BUFG u_audio_buf (.i(audio_clk_raw),.o(audio_clk));

    hdmi_switch_tone u_switch_tone (
        .clk               (sys50),
        .rst_n             (core_rst_n),
        .trigger           (switch_event && !video_mode),
        .audio_clk         (audio_clk_raw),
        .sample_tick       (sample_tick),
        .audio_sample_word (beep_sample_word)
    );

    // ---- SD -> frame buffer loader ------------------------------------------
    wire        fb_we;
    wire [16:0] fb_waddr;
    wire [15:0] fb_wdata;

    wire [31:0] photo_expected_crc;
    wire photo_format_error=photo_format_raw||memory_error;
    sd_loader u_loader (
        .clk          (sys50),
        .rst_n        (photo_rst_n),
        .sd_init_done (sd_init_done&&memory_initialized),
        .fb_ready(memory_sector_ready),
        .load_req     (load_req),
        .base_sector  (base_sector),
        .load_ack     (load_ack),
        .sd_data      (sd_sec_read_data),
        .sd_valid     (sd_sec_read_data_valid),
        .sd_read_end  (sd_sec_read_end),
        .sd_read      (photo_sd_read),
        .sd_addr      (photo_sd_addr),
        .fb_we        (fb_we),
        .fb_addr      (fb_waddr),
        .fb_data      (fb_wdata),
        .load_done    (photo_load_done_raw),
        .expected_crc(photo_expected_crc),.format_error(photo_format_raw)
    );

    wire video_write_bank,video_publish_bank;
    wire video_picture_valid,video_format_error,video_underrun;
    wire [16:0] video_waddr;
    wire [15:0] video_wdata;
    wire video_swap_ack;
    tf_video_player u_video (
        .clk(sys50),.rst_n(media_rst_n),.init_done(sd_init_done&&memory_initialized),
        .fb_ready(memory_sector_ready),.frame_stored(memory_stored),
        .card_sectors(card_sectors),.slot(video_slot),.sample_tick(sample_tick),
        .swap_ack(video_swap_ack),.sd_data(sd_sec_read_data),
        .sd_valid(sd_sec_read_data_valid),.sd_end(sd_sec_read_end),
        .sd_read(video_sd_read),.sd_addr(video_sd_addr),.fb_we(video_we),
        .fb_addr(video_waddr),.fb_data(video_wdata),.write_bank(video_write_bank),
        .swap_request(video_swap_request),.publish_bank(video_publish_bank),
        .picture_valid(video_picture_valid),.pcm(video_pcm),
        .format_error(video_format_error),.underrun(video_underrun),
        .loop_enable(loop_enable),.paused(video_paused),.seconds_gray(video_seconds_gray),
        .stopped(video_stopped)
    );

    // CRC32 of the 153600 BC1 payload bytes. Header and slot padding excluded.
    // This tests actual verified card data, not requests.
    function [31:0] crc32_byte;
        input [31:0] c;
        input [7:0] d;
        reg [31:0] v;
        integer k;
        begin
            v = c ^ {24'd0, d};
            for (k=0; k<8; k=k+1)
                v = v[0] ? ((v >> 1) ^ 32'hedb88320) : (v >> 1);
            crc32_byte = v;
        end
    endfunction

    // 5x7 bitmap font for one glyph (digit 0..9, or 'P'=10, 'I'=11, 'C'=12).
    // sel = {code[3:0], row[2:0]}; returns the 5-column row pattern with
    // bit 4 = the leftmost column.
    function [4:0] digit_row;
        input [6:0] sel;
        begin
            case ((sel[6:3]<10) ? (sel[6:3]*7+sel[2:0]) : sel)
                104: digit_row=5'b10001;
                105: digit_row=5'b10001;
                106: digit_row=5'b10001;
                107: digit_row=5'b10001;
                108: digit_row=5'b01010;
                109: digit_row=5'b01010;
                110: digit_row=5'b00100;
                112: digit_row=5'b11110;
                113: digit_row=5'b10001;
                114: digit_row=5'b10001;
                115: digit_row=5'b10001;
                116: digit_row=5'b10001;
                117: digit_row=5'b10001;
                118: digit_row=5'b11110;
                // digit 0
                7'd0:  digit_row = 5'b01110;
                7'd1:  digit_row = 5'b10001;
                7'd2:  digit_row = 5'b10001;
                7'd3:  digit_row = 5'b10001;
                7'd4:  digit_row = 5'b10001;
                7'd5:  digit_row = 5'b10001;
                7'd6:  digit_row = 5'b01110;
                // digit 1
                7'd7:  digit_row = 5'b00100;
                7'd8:  digit_row = 5'b01100;
                7'd9:  digit_row = 5'b00100;
                7'd10: digit_row = 5'b00100;
                7'd11: digit_row = 5'b00100;
                7'd12: digit_row = 5'b00100;
                7'd13: digit_row = 5'b11111;
                // digit 2
                7'd14: digit_row = 5'b01110;
                7'd15: digit_row = 5'b10001;
                7'd16: digit_row = 5'b00001;
                7'd17: digit_row = 5'b00010;
                7'd18: digit_row = 5'b00100;
                7'd19: digit_row = 5'b01000;
                7'd20: digit_row = 5'b11111;
                // digit 3
                7'd21: digit_row = 5'b01110;
                7'd22: digit_row = 5'b10001;
                7'd23: digit_row = 5'b00001;
                7'd24: digit_row = 5'b00110;
                7'd25: digit_row = 5'b00001;
                7'd26: digit_row = 5'b10001;
                7'd27: digit_row = 5'b01110;
                // digit 4
                7'd28: digit_row = 5'b00010;
                7'd29: digit_row = 5'b00110;
                7'd30: digit_row = 5'b01010;
                7'd31: digit_row = 5'b10010;
                7'd32: digit_row = 5'b11111;
                7'd33: digit_row = 5'b00010;
                7'd34: digit_row = 5'b00010;
                // digit 5
                7'd35: digit_row = 5'b11111;
                7'd36: digit_row = 5'b10000;
                7'd37: digit_row = 5'b11110;
                7'd38: digit_row = 5'b00001;
                7'd39: digit_row = 5'b00001;
                7'd40: digit_row = 5'b10001;
                7'd41: digit_row = 5'b01110;
                // digit 6
                7'd42: digit_row = 5'b01110;
                7'd43: digit_row = 5'b10001;
                7'd44: digit_row = 5'b10000;
                7'd45: digit_row = 5'b11110;
                7'd46: digit_row = 5'b10001;
                7'd47: digit_row = 5'b10001;
                7'd48: digit_row = 5'b01110;
                // digit 7
                7'd49: digit_row = 5'b11111;
                7'd50: digit_row = 5'b00001;
                7'd51: digit_row = 5'b00010;
                7'd52: digit_row = 5'b00100;
                7'd53: digit_row = 5'b01000;
                7'd54: digit_row = 5'b01000;
                7'd55: digit_row = 5'b01000;
                // digit 8
                7'd56: digit_row = 5'b01110;
                7'd57: digit_row = 5'b10001;
                7'd58: digit_row = 5'b10001;
                7'd59: digit_row = 5'b01110;
                7'd60: digit_row = 5'b10001;
                7'd61: digit_row = 5'b10001;
                7'd62: digit_row = 5'b01110;
                // digit 9
                7'd63: digit_row = 5'b01110;
                7'd64: digit_row = 5'b10001;
                7'd65: digit_row = 5'b10001;
                7'd66: digit_row = 5'b01111;
                7'd67: digit_row = 5'b00001;
                7'd68: digit_row = 5'b10001;
                7'd69: digit_row = 5'b01110;
                // 'P' (code 10)
                7'd80: digit_row = 5'b11110;
                7'd81: digit_row = 5'b10001;
                7'd82: digit_row = 5'b10001;
                7'd83: digit_row = 5'b11110;
                7'd84: digit_row = 5'b10000;
                7'd85: digit_row = 5'b10000;
                7'd86: digit_row = 5'b10000;
                // 'I' (code 11)
                7'd88: digit_row = 5'b01110;
                7'd89: digit_row = 5'b00100;
                7'd90: digit_row = 5'b00100;
                7'd91: digit_row = 5'b00100;
                7'd92: digit_row = 5'b00100;
                7'd93: digit_row = 5'b00100;
                7'd94: digit_row = 5'b01110;
                // 'C' (code 12)
                7'd96: digit_row = 5'b01110;
                7'd97: digit_row = 5'b10001;
                7'd98: digit_row = 5'b10000;
                7'd99: digit_row = 5'b10000;
                7'd100: digit_row = 5'b10000;
                7'd101: digit_row = 5'b10001;
                7'd102: digit_row = 5'b01110;
                default: digit_row = 5'b00000;
            endcase
        end
    endfunction
    reg [31:0] image_crc;
    reg [17:0] crc_byte_count;
    wire [31:0] photo_crc_word=crc32_byte(crc32_byte(image_crc,fb_wdata[7:0]),fb_wdata[15:8]);
    always @(posedge sys50 or negedge core_rst_n) begin
        if(!core_rst_n)begin image_crc<=32'hffffffff;crc_byte_count<=0;end
        else if(load_ack)begin image_crc<=32'hffffffff;crc_byte_count<=0;end
        else if(fb_we)begin image_crc<=photo_crc_word;crc_byte_count<=crc_byte_count+18'd2;end
    end
    wire image_crc_ok=(crc_byte_count==18'd153600)&&((~image_crc)==photo_expected_crc)&&!photo_format_error;

    // Diagnostic picture generator. Writes pass through the SAME RAM write
    // port, parity banking and bilinear scaler used by SD images.
    reg [16:0] ram_test_addr;
    reg [7:0] ram_test_x,ram_test_y;
    reg ram_test_done;
    wire ram_test_we=test_mode&&!ram_test_done&&memory_word_ready;
    wire ram_test_border=(ram_test_x==0)||(ram_test_x==159)||(ram_test_y==0)||(ram_test_y==119);
    wire [15:0] test_color=ram_test_border?16'hffff:
            (ram_test_y<60)?((ram_test_x<80)?16'hf800:16'h07e0):
                             ((ram_test_x<80)?16'h001f:16'hffe0);
    // A constant-color BC1 block: two equal endpoints and sixteen index zero.
    wire [15:0] ram_test_data=ram_test_addr[1]?16'd0:test_color;
    always @(posedge sys50 or negedge core_rst_n)begin
        if(!core_rst_n)begin ram_test_addr<=0;ram_test_x<=0;ram_test_y<=0;ram_test_done<=0;end
        else if(ram_test_we)begin
            if(ram_test_addr==76799)ram_test_done<=1;
            else ram_test_addr<=ram_test_addr+1'b1;
            if(ram_test_addr[1:0]==3)begin
                if(ram_test_x==159)begin ram_test_x<=0;ram_test_y<=ram_test_y+1'b1;end
                else ram_test_x<=ram_test_x+1'b1;
            end
        end
    end

    // ---- SiP SDRAM frame storage and native raster ------------------------
    wire [7:0] VGA_R,VGA_G,VGA_B;
    wire [2:0] hdmi_tmds;wire hdmi_tmds_clock;
    wire memory_rst_n=core_rst_n&&(mode_reset==0);
    reg [1:0] memory_pixel_reset;
    always @(posedge pixel_clk or negedge memory_rst_n)
        if(!memory_rst_n)memory_pixel_reset<=0;
        else memory_pixel_reset<={memory_pixel_reset[0],1'b1};
    reg [1:0] video_mode_sync,media_valid_sync,media_error_sync,copy_error_sync;
    wire video_mode_pix;
    reg [1:0] video_format_sync,video_under_sync,video_sd_error_sync;
    reg video_sd_error_seen;
    wire copy_error=memory_error;
    wire [23:0] native_rgb;
    reg video_front,video_ack_pix;
    reg [1:0] swap_sync;
    always @(posedge pixel_clk or negedge memory_rst_n)begin
        if(!memory_rst_n)begin video_front<=0;video_ack_pix<=0;swap_sync<=0;end
        else begin
            swap_sync<={swap_sync[0],video_swap_request};
            if((hdmi_cx==0)&&(hdmi_cy==480)&&(swap_sync[1]!=video_ack_pix))begin
                video_front<=video_publish_bank;video_ack_pix<=swap_sync[1];
            end
        end
    end
    assign video_swap_ack=video_ack_pix;
    sdram_media u_sdram(
        .clk(sys50),.rst_n(memory_rst_n),.pixel_clk(pixel_clk),.pixel_rst_n(memory_pixel_reset[1]),
        .we(test_mode?ram_test_we:(video_mode?video_we:fb_we)),
        .bank(test_mode?1'b0:(video_mode?video_write_bank:photo_write_bank)),
        .waddr(test_mode?ram_test_addr:(video_mode?video_waddr:fb_waddr)),
        .din(test_mode?ram_test_data:(video_mode?video_wdata:fb_wdata)),
        .x(hdmi_cx),.y(hdmi_cy),.slide_offset(photo_offset_pix),
        .front(video_mode_pix?video_front:photo_front_pix),
        .slide_enable(!video_mode_pix&&!test_mode),
        .effect(effect_pix),
        .word_ready(memory_word_ready),.sector_ready(memory_sector_ready),.stored(memory_stored),
        .initialized(memory_initialized),.error(memory_error),.rgb(native_rgb));
    assign {VGA_R,VGA_G,VGA_B}=native_rgb;
    always @(posedge sys50 or negedge media_rst_n)begin
        if(!media_rst_n)video_sd_error_seen<=0;else if(sd_rx_error)video_sd_error_seen<=1;
    end
    always @(posedge pixel_clk or negedge pixel_rst_n)begin
        if(!pixel_rst_n)hdmi_vblank<=0;else hdmi_vblank<=(hdmi_cy>=480);
    end
    always @(posedge pixel_clk or negedge pixel_rst_n)begin
        if(!pixel_rst_n)begin
            video_mode_sync<=0;media_valid_sync<=0;media_error_sync<=0;copy_error_sync<=0;
            video_format_sync<=0;video_under_sync<=0;video_sd_error_sync<=0;
        end else begin
            video_mode_sync<={video_mode_sync[0],media_rst_n};
            media_valid_sync<={media_valid_sync[0],video_picture_valid&&!memory_error};
            media_error_sync<={media_error_sync[0],video_format_error|video_underrun|memory_error};
            copy_error_sync<={copy_error_sync[0],memory_error};
            video_format_sync<={video_format_sync[0],video_format_error};
            video_under_sync<={video_under_sync[0],video_underrun};
            video_sd_error_sync<={video_sd_error_sync[0],video_sd_error_seen};
        end
    end
    assign video_mode_pix=video_mode_sync[1];

    // A visible key acknowledgement does not depend on successful SD init.
    reg [23:0] key_feedback_count;
    reg test_page;
    wire key_feedback = (key_feedback_count != 24'd0);
    always @(posedge sys50 or negedge core_rst_n) begin
        if (!core_rst_n) begin
            key_feedback_count <= 24'd0;
            test_page <= 1'b0;
        end else begin
            if (key_press) begin
                key_feedback_count <= 24'd10000000;
                test_page <= ~test_page;
            end else if (key_feedback_count != 0)
                key_feedback_count <= key_feedback_count - 1'b1;
        end
    end
    reg [1:0] valid_sync, test_sync, page_sync, ram_done_sync, crc_ok_sync, rx_error_sync;
    reg [1:0] photo_loaded_sync;
    reg [9:0] pattern_x, pattern_y;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            valid_sync <= 2'b00;
            photo_loaded_sync<=0;
            ram_done_sync <= 2'b00;
            crc_ok_sync <= 2'b00;
            rx_error_sync <= 2'b00;
            test_sync <= 2'b00;
            page_sync <= 2'b00;
            pattern_x <= 10'd0;
            pattern_y <= 10'd0;
        end else begin
            valid_sync <= {valid_sync[0], photo_valid};
            photo_loaded_sync<={photo_loaded_sync[0],load_done};
            ram_done_sync <= {ram_done_sync[0], ram_test_done&&memory_stored};
            crc_ok_sync <= {crc_ok_sync[0], image_crc_ok};
            rx_error_sync <= {rx_error_sync[0], sd_rx_error|photo_format_error};
            test_sync <= {test_sync[0], test_mode};
            page_sync <= {page_sync[0], test_page};
            // Align with the HDMI core's registered active-video flag.
            pattern_x <= hdmi_cx;
            pattern_y <= hdmi_cy;
        end
    end
    // ---- overlay geometry ----------------------------------------------------
    localparam [9:0] TEXT_X     = 10'd8;      // "PIC#" text badge, top-left
    localparam [9:0] TEXT_Y     = 10'd8;
    localparam [2:0] TEXT_SCALE = 3'd3;       // each font pixel = 3x3 screen px
    localparam [9:0] WAVE_X0    = 10'd512;    // audio scope, top-right (640-128)
    localparam [9:0] WAVE_W     = 10'd128;
    localparam [9:0] WAVE_H     = 10'd48;

    // Image index 0..3 is base_sector[11:9]; sync into the pixel domain and
    // show it 1-based so image1..image4 read as "1".."4".
    reg [2:0] img_sync0, img_sync1;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            img_sync0 <= 3'd0;
            img_sync1 <= 3'd0;
        end else begin
            img_sync0 <= base_sector[11:9];
            img_sync1 <= img_sync0;
        end
    end
    wire [3:0] image_number = {1'b0, img_sync1} + 4'd1;
    reg [4:0] slot_meta,slot_pix;
    always @(posedge pixel_clk) begin slot_meta<=video_slot;slot_pix<=slot_meta;end
    wire [5:0] video_number={1'b0,slot_pix}+6'd1;

    // SW1 (C8) DIP switch: up = "1" -> show the audio scope, down = "0" -> hide it.
    // 2-stage synchronizer into the pixel domain (the switch is a static async input).
    reg [1:0] sw1_sync;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) sw1_sync <= 2'b00;
        else              sw1_sync <= {sw1_sync[0], sw1};
    end
    wire show_wave = sw1_sync[1];

    // Bring the beep PCM (changes at 48 kHz, otherwise 0) into the pixel domain.
    // Signed PCM is required for both positive and negative waveform samples.
    reg signed [15:0] pcm_s0, pcm_s1;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            pcm_s0 <= 16'd0;
            pcm_s1 <= 16'd0;
        end else begin
            pcm_s0 <= audio_sample_word[15:0];
            pcm_s1 <= pcm_s0;
        end
    end
    // Vertical offset in [-23, 23]: yoff = pcm * 23 / 8192 (arithmetic >> 13).
    wire signed [18:0] pcm_scaled = $signed(pcm_s1) * 23'sd23;
    wire signed [20:0] video_scaled=$signed(pcm_s1)*21'sd23;
    wire signed [5:0] pcm_yoff=video_mode_pix ? video_scaled[20:15] : pcm_scaled[18:13];

    // Live scope in both modes: silence flushes the last beep in 128 samples
    // (about 2.7 ms) instead of retaining a frozen square wave.
    reg signed [5:0] wave_ring [0:127];
    reg [9:0] wave_push_cnt;
    integer    wi;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            wave_push_cnt <= 10'd0;
            for (wi = 0; wi < 128; wi = wi + 1)
                wave_ring[wi] <= 6'sd0;
        end else begin
                if (wave_push_cnt == 10'd520) begin
                    wave_push_cnt <= 10'd0;
                    for (wi = 0; wi < 127; wi = wi + 1)
                        wave_ring[wi] <= wave_ring[wi + 1];
                    wave_ring[127] <= pcm_yoff;
                end else begin
                    wave_push_cnt <= wave_push_cnt + 1'b1;
                end
        end
    end

    // "PIC#" text badge: 4 characters (P I C digit), 5x7 glyphs at TEXT_SCALE.
    // Each character cell is 6 glyph columns wide (5 glyph + 1 gap) so letters
    // do not touch.
    wire [9:0] text_width=video_mode_pix ? 10'd90 : 10'd72;
    wire in_text = (pattern_x >= TEXT_X) && (pattern_x < TEXT_X + text_width) &&
                   (pattern_y >= TEXT_Y) && (pattern_y < TEXT_Y + 7*TEXT_SCALE);
    wire [9:0] tx = pattern_x - TEXT_X;
    wire [9:0] ty = pattern_y - TEXT_Y;
    wire [2:0] char_idx = (tx < 10'd18) ? 3'd0 : (tx < 10'd36) ? 3'd1 :
                          (tx < 10'd54) ? 3'd2 : (tx < 10'd72) ? 3'd3 : 3'd4;
    wire [9:0] char_base = char_idx * 10'd18;
    wire [4:0] cell_x   = (tx - char_base) / TEXT_SCALE;   // 0..5 (5 = gap)
    wire [2:0] frow     = ty / TEXT_SCALE;                 // 0..6
    wire [3:0] char_code = video_mode_pix ?
                           ((char_idx==0)?4'd13:(char_idx==1)?4'd11:(char_idx==2)?4'd14:
                            (char_idx==3)?(video_number/10):(video_number%10)) :
                           (char_idx == 3'd0) ? 4'd10 :    // 'P'
                           (char_idx == 3'd1) ? 4'd11 :    // 'I'
                           (char_idx == 3'd2) ? 4'd12 :    // 'C'
                           image_number[3:0];              // digit 1..4
    wire [4:0] glyph_bits = digit_row({char_code[3:0], frow});
    wire       glyph_active = (cell_x < 5);
    wire [2:0] bit_idx      = glyph_active ? (3'd4 - cell_x[2:0]) : 3'd0;
    wire       text_px      = glyph_active && glyph_bits[bit_idx];

    // Mailbox keeps the complete timestamp coherent even on a loop/replay reset,
    // when returning to zero can change more than one Gray bit at once.
    reg [9:0] seconds_mailbox,seconds_sync;
    reg [1:0] stamp_request_sync,stamp_ack_sync;
    reg stamp_request,stamp_ack,stamp_seen;
    always @(posedge sys50 or negedge core_rst_n) begin
        if(!core_rst_n) begin stamp_request_sync<=0;stamp_ack<=0;seconds_mailbox<=0;end
        else begin
            stamp_request_sync<={stamp_request_sync[0],stamp_request};
            if(stamp_request_sync[1]!=stamp_ack) begin
                seconds_mailbox<=video_seconds_gray;stamp_ack<=stamp_request_sync[1];
            end
        end
    end
    reg [1:0] paused_sync;
    reg [15:0] time_digits;
    function [9:0] gray_decode;
        input [9:0] g;
        integer j;
        begin gray_decode[9]=g[9];
            for(j=8;j>=0;j=j-1) gray_decode[j]=gray_decode[j+1]^g[j];
        end
    endfunction
    wire [9:0] elapsed_seconds=gray_decode(seconds_sync);
    wire [3:0] minute_tens=elapsed_seconds/600;
    wire [3:0] minute_ones=(elapsed_seconds/60)%10;
    wire [3:0] second_tens=(elapsed_seconds%60)/10;
    wire [3:0] second_ones=elapsed_seconds%10;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            seconds_sync<=0;time_digits<=0;paused_sync<=0;
            stamp_request<=0;stamp_ack_sync<=0;stamp_seen<=0;
            photo_offset_meta<=0;photo_offset_sync<=0;photo_offset_pix<=0;
            photo_front_sync<=0;photo_front_pix<=0;
            effect_meta<=0;effect_sync<=0;effect_previous<=0;effect_pix<=0;
            effect_choice_meta<=0;effect_choice_sync<=0;effect_choice_previous<=0;effect_choice_pix<=0;
        end else begin
            stamp_ack_sync<={stamp_ack_sync[0],stamp_ack};
            if(stamp_ack_sync[1]!=stamp_seen) begin
                seconds_sync<=seconds_mailbox;stamp_seen<=stamp_ack_sync[1];
            end
            paused_sync<={paused_sync[0],video_paused};
            photo_offset_meta<=photo_offset;photo_offset_sync<=photo_offset_meta;
            photo_front_sync<={photo_front_sync[0],photo_front};
            effect_meta<=photo_effect_active;effect_sync<=effect_meta;effect_previous<=effect_sync;
            effect_choice_meta<=photo_effect;effect_choice_sync<=effect_choice_meta;
            effect_choice_previous<=effect_choice_sync;
            // Snapshot well inside blank, before the scaler prefetches pixel (0,0).
            // System-side progress only changes near the START of blank.
            if((hdmi_cx==799)&&(hdmi_cy==500)) begin
                photo_offset_pix<=photo_offset_sync;photo_front_pix<=photo_front_sync[1];
                if((effect_sync==effect_previous)&&(effect_sync<=2)) effect_pix<=effect_sync;
                if((effect_choice_sync==effect_choice_previous)&&(effect_choice_sync<=2))
                    effect_choice_pix<=effect_choice_sync;
            end
            if((hdmi_cx==799)&&(hdmi_cy==524)) begin
                if(stamp_request==stamp_seen) stamp_request<=~stamp_request;
                time_digits<={minute_tens,minute_ones,second_tens,second_ones};
            end
        end
    end
    wire in_time=video_mode_pix&&(pattern_x>=8)&&(pattern_x<98)&&
                 (pattern_y>=35)&&(pattern_y<56);
    wire [9:0] time_x=pattern_x-10'd8;
    wire [2:0] time_char=(time_x<18)?0:(time_x<36)?1:(time_x<54)?2:(time_x<72)?3:4;
    wire [4:0] time_col=(time_x-time_char*18)/3;
    wire [2:0] time_row=(pattern_y-10'd35)/3;
    wire [3:0] time_code=(time_char==0)?time_digits[15:12]:(time_char==1)?time_digits[11:8]:
                          (time_char==3)?time_digits[7:4]:time_digits[3:0];
    wire [4:0] time_bits=digit_row({time_code,time_row});
    wire time_dot=(time_char==2)&&(time_col==2)&&((time_row==2)||(time_row==4));
    wire time_ink=(time_char==2)?time_dot:((time_col<5)&&time_bits[(time_col<5)?4-time_col:0]);
    wire [23:0] time_rgb=time_ink ? (paused_sync[1]?24'hffcc00:24'hffffff) : 24'h101010;

    wire in_wave = (pattern_x >= WAVE_X0) && (pattern_x < WAVE_X0 + WAVE_W) &&
                   (pattern_y < WAVE_H);
    wire [6:0] wave_col       = pattern_x[6:0];              // 0..127
    wire [6:0] wave_col_prev  = (wave_col == 7'd0) ? 7'd0 : wave_col - 1'b1;
    wire signed [5:0] wave_y_cur   = wave_ring[wave_col];
    wire signed [5:0] wave_y_prev  = wave_ring[wave_col_prev];
    wire signed [6:0] wave_px_cur  = 7'sd24 - wave_y_cur;
    wire signed [6:0] wave_px_prev = 7'sd24 - wave_y_prev;
    wire signed [6:0] wave_px_lo   = (wave_px_cur <= wave_px_prev) ? wave_px_cur  : wave_px_prev;
    wire signed [6:0] wave_px_hi   = (wave_px_cur >= wave_px_prev) ? wave_px_cur  : wave_px_prev;
    wire signed [6:0] wave_row     = {1'b0, pattern_y[6:0]};  // 0..47
    wire wave_trace = (wave_row >= wave_px_lo) && (wave_row <= wave_px_hi);
    wire wave_border = (wave_col == 7'd0) || (wave_col == (WAVE_W - 1)) ||
                       (pattern_y == 10'd0) || (pattern_y == (WAVE_H - 1));

    wire [23:0] bars_rgb = (pattern_x < 10'd213) ? 24'hff0000 :
                             (pattern_x < 10'd426) ? 24'h00ff00 : 24'h0000ff;
    // 16x16 corner marker kept only as the purple "read error / retrying"
    // indicator shown while an image is still loading (screen black).
    wire crc_marker = (pattern_x < 10'd16) && (pattern_y < 10'd16);
    wire [23:0] loading_rgb = (crc_marker && rx_error_sync[1]) ? 24'hff00ff : 24'h000000;

    // 1px light border around the "PIC#" badge for contrast over any image.
    wire text_border = in_text &&
                       ((pattern_x == TEXT_X) || (pattern_x == TEXT_X + text_width - 1) ||
                        (pattern_y == TEXT_Y) || (pattern_y == TEXT_Y + 7*TEXT_SCALE - 1));
    wire [23:0] text_rgb = text_border ? 24'hc0c0c0 :
                           text_px     ? 24'hffffff : 24'h101010;

    // Normal mode: image + "PIC#" text (top-left) + audio scope (top-right).
    wire [23:0] image_rgb = {VGA_R, VGA_G, VGA_B};
    wire [23:0] adjusted_image_rgb;
    wire osd_active;
    wire [23:0] osd_rgb;
    media_osd u_media_osd(.clk(pixel_clk),.rst_n(pixel_rst_n),
        .photo_effect(effect_choice_pix),
        .cx(hdmi_cx),.cy(hdmi_cy),.x(pattern_x),.y(pattern_y),
        .level_gray(brightness_gray),.settings(settings_mode),.loop_enable(loop_enable),
        .video(video_mode_pix),.paused(paused_sync[1]),
        .ready(video_mode_pix?media_valid_sync[1]:valid_sync[1]),
        .format_error(video_mode_pix?video_format_sync[1]:photo_format_error),
        .copy_error(video_mode_pix&&copy_error_sync[1]),
        .underrun(video_mode_pix&&video_under_sync[1]),
        .sd_retry(video_mode_pix?video_sd_error_sync[1]:rx_error_sync[1]),
        .image_rgb(image_rgb),.adjusted_rgb(adjusted_image_rgb),
        .active(osd_active),.rgb(osd_rgb));
    wire [23:0] shown_rgb = (in_wave && show_wave) ? (wave_trace ? 24'hffff00 :
                                       wave_border ? 24'h808080 : 24'h101010) :
                            in_text ? text_rgb : in_time ? time_rgb :
                            adjusted_image_rgb;
    // Distinguish malformed media (red), starvation (amber), RAM CRC (blue).
    // Purple at x=16..31 records an SD retry/recovery since replay/slot change.
    wire [23:0] normal_media_rgb = video_mode_pix ?
        ((crc_marker&&copy_error_sync[1]) ? 24'h0000ff :
         (crc_marker&&video_format_sync[1]) ? 24'hff0000 :
         (crc_marker&&video_under_sync[1]) ? 24'hffbf00 :
         ((pattern_x>=16)&&(pattern_x<32)&&(pattern_y<16)&&video_sd_error_sync[1]) ? 24'hff00ff :
         (media_valid_sync[1] ? shown_rgb : (in_text ? text_rgb : in_time ? time_rgb : 24'h000000))) :
        (valid_sync[1] ? ((crc_marker&&rx_error_sync[1]&&!photo_loaded_sync[1]) ?
            24'hff00ff : shown_rgb) : loading_rgb);
    wire [23:0] normal_rgb=osd_active?osd_rgb:normal_media_rgb;
    wire [23:0] ram_picture_rgb = ram_done_sync[1] ? {VGA_R, VGA_G, VGA_B} : 24'h000000;
    wire [23:0] display_rgb = test_sync[1] ? (page_sync[1] ? ram_picture_rgb : bars_rgb) : normal_rgb;

    // HDMI data islands carry 48 kHz stereo samples and the Audio InfoFrame.
    // The original encrypted DVI-only block remains registered but unused.
    hdmi #(
        .VIDEO_ID_CODE      (1),
        .DVI_OUTPUT         (1'b0),
        .VIDEO_REFRESH_RATE (60.0),
        .AUDIO_RATE         (48000),
        .AUDIO_BIT_WIDTH    (16),
        .VENDOR_NAME        ({"HX4S20", 16'd0}),
        .PRODUCT_DESCRIPTION({"TF RGB565 HDMI", 16'd0})
    ) u_hdmi (
        .clk_pixel_x5      (pixel_clk_5x),
        .clk_pixel         (pixel_clk),
        .clk_audio         (audio_clk),
        .reset             (~pixel_rst_n),
        .rgb               (display_rgb),
        .audio_sample_word (audio_sample_word),
        .tmds              (hdmi_tmds),
        .tmds_clock        (hdmi_tmds_clock),
        .cx                (hdmi_cx),
        .cy                (hdmi_cy),
        .frame_width       (),
        .frame_height      (),
        .screen_width      (),
        .screen_height     ()
    );

    assign HDMI_CLK_P = hdmi_tmds_clock;
    assign HDMI_D2_P  = hdmi_tmds[2];
    assign HDMI_D1_P  = hdmi_tmds[1];
    assign HDMI_D0_P  = hdmi_tmds[0];

    // ---- fan the same TMDS signal out to the board's 2nd HDMI connector -----
    // (the hdmi_tx_display_A demo does exactly this, so the monitor works on
    //  either connector)
    assign HDMI_CLK_P1 = HDMI_CLK_P;
    assign HDMI_D2_P1  = HDMI_D2_P;
    assign HDMI_D1_P1  = HDMI_D1_P;
    assign HDMI_D0_P1  = HDMI_D0_P;

    // ---- status LEDs (common-anode -> active-low) ----------------------------
    assign LED[0] = (~(test_mode || sd_init_done)) ^ key_feedback;   // on = SD card initialized
    assign LED[1] = ~(test_mode || (video_mode ? video_picture_valid : load_done));


endmodule

// ============================================================================
// Helper modules (kept in this file so TD compiles them without needing to
// re-register separate source files in the project).
// ============================================================================

// Debounced SW3 settings. Brightness is a bounded, registered Gray code so
// the pixel-domain synchronizer never captures a mixed multi-bit level.
module ui_controls #(parameter DEBOUNCE_CYCLES=500000)(
 input wire clk,rst_n,sw3,next_press,previous_press,
 output reg settings,output reg [3:0] level_gray,
 output wire nav_next,nav_previous
);
 reg [1:0] switch_meta;
 reg [18:0] debounce;
 reg [3:0] level;
 wire [3:0] selected=previous_press?((level==0)?4'd0:level-1'b1):
                                      ((level==8)?4'd8:level+1'b1);
 assign nav_next=next_press&&!settings&&!switch_meta[1];
 assign nav_previous=previous_press&&!settings&&!switch_meta[1];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin switch_meta<=0;settings<=0;debounce<=0;level<=4;level_gray<=6;end
  else begin
   switch_meta<={switch_meta[0],sw3};
   if(switch_meta[1]==settings)debounce<=0;
   else if(debounce==DEBOUNCE_CYCLES-1)begin settings<=switch_meta[1];debounce<=0;end
   else debounce<=debounce+1'b1;
   if(settings&&(next_press||previous_press))begin
    level<=selected;level_gray<=selected^(selected>>1);
   end
  end
 end
endmodule

// Small constant-font OSD. No frame RAM and no new clock domain.
// Slow control inputs are synchronized and frozen at vertical blank.
// Existing video latency is unchanged: brightness is combinational.
module media_osd(
 input wire [1:0] photo_effect,
 input wire clk,rst_n,input wire [9:0] cx,cy,x,y,
 input wire [3:0] level_gray,
 input wire settings,loop_enable,video,paused,ready,format_error,copy_error,underrun,sd_retry,
 input wire [23:0] image_rgb,
 output wire [23:0] adjusted_rgb,
 output wire active,output wire [23:0] rgb
);
 reg [3:0] level_meta,level_sync,level_pix;
 reg [8:0] state_meta,state_sync,state_pix;
 reg [7:0] popup_frames;
 reg [10:0] scroll_pos;
 wire frame_tick=(cx==799)&&(cy==524);
 function [3:0] ungray;input [3:0] a;
 begin ungray[3]=a[3];ungray[2]=a[3]^a[2];ungray[1]=a[3]^a[2]^a[1];ungray[0]=^a;end endfunction
 wire [3:0] decoded=ungray(level_sync);
 wire settings_p=state_pix[8],loop_p=state_pix[7],video_p=state_pix[6],pause_p=state_pix[5];
 wire ready_p=state_pix[4],format_p=state_pix[3],copy_p=state_pix[2],under_p=state_pix[1],retry_p=state_pix[0];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin level_meta<=6;level_sync<=6;level_pix<=4;
   state_meta<=0;state_sync<=0;state_pix<=0;popup_frames<=0;scroll_pos<=0;end
  else begin
   level_meta<=level_gray;level_sync<=level_meta;
   state_meta<={settings,loop_enable,video,paused,ready,format_error,copy_error,underrun,sd_retry};
   state_sync<=state_meta;
   if(frame_tick)begin
    if(decoded<=8)level_pix<=decoded;
    state_pix<=state_sync;
    if((decoded!=level_pix)||(state_sync[8]!=settings_p))popup_frames<=180;
    else if(popup_frames!=0)popup_frames<=popup_frames-1'b1;
    scroll_pos<=(scroll_pos==1407)?11'd0:scroll_pos+1'b1;
   end
  end
 end
 function [7:0] brighten;input [7:0] value;input [3:0] b;
 reg [6:0] amount;reg [8:0] sum;
 begin
  if(b>=4)begin amount=(b-4)*16;sum={1'b0,value}+amount;brighten=sum[8]?8'hff:sum[7:0];end
  else begin amount=(4-b)*16;brighten=(value<amount)?8'd0:value-amount;end
 end endfunction
 // Keep truly black source pixels (including contain bars) black.
 assign adjusted_rgb=(image_rgb==0)?24'd0:
   {brighten(image_rgb[23:16],level_pix),brighten(image_rgb[15:8],level_pix),brighten(image_rgb[7:0],level_pix)};
 function [34:0] glyph;input [7:0] ch;
 begin case(ch)
    8'd48:glyph=35'b01110100011001110101110011000101110;
    8'd49:glyph=35'b00100011000010000100001000010001110;
    8'd50:glyph=35'b01110100010000100010001000100011111;
    8'd51:glyph=35'b11110000010000101110000010000111110;
    8'd52:glyph=35'b00010001100101010010111110001000010;
    8'd53:glyph=35'b11111100001000011110000010000111110;
    8'd54:glyph=35'b01110100001000011110100011000101110;
    8'd55:glyph=35'b11111000010001000100010000100001000;
    8'd56:glyph=35'b01110100011000101110100011000101110;
    8'd57:glyph=35'b01110100011000101111000010000101110;
    8'd65:glyph=35'b01110100011000111111100011000110001;
    8'd66:glyph=35'b11110100011000111110100011000111110;
    8'd67:glyph=35'b01111100001000010000100001000001111;
    8'd68:glyph=35'b11110100011000110001100011000111110;
    8'd69:glyph=35'b11111100001000011110100001000011111;
    8'd70:glyph=35'b11111100001000011110100001000010000;
    8'd71:glyph=35'b01111100001000010111100011000101111;
    8'd72:glyph=35'b10001100011000111111100011000110001;
    8'd73:glyph=35'b01110001000010000100001000010001110;
    8'd74:glyph=35'b00111000100001000010000101001001100;
    8'd75:glyph=35'b10001100101010011000101001001010001;
    8'd76:glyph=35'b10000100001000010000100001000011111;
    8'd77:glyph=35'b10001110111010110101100011000110001;
    8'd78:glyph=35'b10001110011010110011100011000110001;
    8'd79:glyph=35'b01110100011000110001100011000101110;
    8'd80:glyph=35'b11110100011000111110100001000010000;
    8'd81:glyph=35'b01110100011000110001101011001001101;
    8'd82:glyph=35'b11110100011000111110101001001010001;
    8'd83:glyph=35'b01111100001000001110000010000111110;
    8'd84:glyph=35'b11111001000010000100001000010000100;
    8'd85:glyph=35'b10001100011000110001100011000101110;
    8'd86:glyph=35'b10001100011000110001100010101000100;
    8'd87:glyph=35'b10001100011000110101101011010101010;
    8'd88:glyph=35'b10001100010101000100010101000110001;
    8'd89:glyph=35'b10001100010101000100001000010000100;
    8'd90:glyph=35'b11111000010001000100010001000011111;
    8'd43:glyph=35'b00000001000010011111001000010000000;
    8'd45:glyph=35'b00000000000000011111000000000000000;
    8'd47:glyph=35'b00001000100001000100010000100010000;
    8'd58:glyph=35'b00000001000010000000001000010000000;
    default:glyph=35'd0;
 endcase end endfunction
 function ink;input [7:0] ch;input [2:0] row,col;reg [34:0] bits;
 begin bits=glyph(ch);ink=((row<7)&&(col<5))?bits[34-row*5-col]:1'b0;end endfunction
 wire [3:0] magnitude=(level_pix>=4)?level_pix-4:4-level_pix;
 wire [7:0] sign_char=(level_pix>=4)?8'h2b:8'h2d;
 wire [7:0] digit_char=8'h30+{4'd0,magnitude};
 wire [191:0] brightness_word={"BRIGHTNESS ",sign_char,digit_char,"           "};
 reg [191:0] status_word,fault_word,panel_word;
 reg panel;
 reg [9:0] panel_y;
 reg [23:0] text_color;
 always @*begin
  if(settings_p)status_word=video_p?(pause_p?"VIDEO PAUSE SETTINGS    ":"VIDEO PLAY SETTINGS     "):"PHOTO SETTINGS          ";
  else status_word=video_p?(pause_p?(loop_p?"VIDEO PAUSE LOOP        ":"VIDEO PAUSE ONCE        "):
                             (loop_p?"VIDEO PLAY LOOP         ":"VIDEO PLAY ONCE         ")):
                           (loop_p?"PHOTO AUTO              ":"PHOTO MANUAL            ");
  fault_word=copy_p?"FRAME CHECK ERROR       ":format_p?"MEDIA FORMAT ERROR      ":
             under_p?"AUDIO UNDERRUN HISTORY  ":retry_p?"SD RETRY HISTORY        ":"LOADING MEDIA           ";
  panel=0;panel_word=status_word;panel_y=0;text_color=24'hffffff;
  if((x>=8)&&(x<296))begin
   if(!video_p&&(y>=35)&&(y<49))begin
    panel=1;panel_y=y-35;text_color=24'h66ddff;
    case(photo_effect)
     1:panel_word="FX PAPER PLANE KEY4 NEXT";
     2:panel_word="FX DISSOLVE    KEY4 NEXT";
     default:panel_word="FX SLIDE       KEY4 NEXT";
    endcase
   end
   else if((y>=64)&&(y<78))begin panel=1;panel_y=y-64;end
   else if((settings_p||popup_frames!=0)&&(y>=84)&&(y<98))begin
    panel=1;panel_y=y-84;panel_word=brightness_word;text_color=24'hffcc00;end
   else if(settings_p&&(y>=104)&&(y<118))begin
    panel=1;panel_y=y-104;panel_word="KEY2 + KEY3 - SW3 EXIT  ";text_color=24'h66ddff;end
   else if((copy_p||format_p||under_p||retry_p||!ready_p)&&(y>=124)&&(y<138))begin
    panel=1;panel_y=y-124;panel_word=fault_word;
    text_color=(copy_p||format_p)?24'hff5555:24'hffcc00;end
  end
 end
 wire [9:0] panel_x=x-10'd8;
 wire [4:0] panel_index=panel_x/12;
 wire [2:0] panel_col=(panel_x%12)/2,panel_row=panel_y/2;
 wire [7:0] panel_char=(panel_index<24)?panel_word[191-panel_index*8-:8]:8'h20;
 wire panel_ink=ink(panel_char,panel_row,panel_col);
 localparam [511:0] MESSAGE="FPGA HDMI MULTIMEDIA - PHOTO / VIDEO / AUDIO - BC1 640X480      ";
 wire [10:0] scroll_x={1'b0,x}+scroll_pos;
 wire [10:0] message_x=scroll_x-11'd640;
 wire [5:0] message_index=message_x/12;
 wire [7:0] message_char=MESSAGE[511-message_index*8-:8];
 wire strip=(y>=448)&&(y<480)&&(x<640);
 wire message_area=strip&&(y>=456)&&(y<470)&&(scroll_x>=640)&&(scroll_x<1408);
 wire [2:0] message_row=(y-10'd456)/2,message_col=(message_x%12)/2;
 wire message_ink=message_area&&ink(message_char,message_row,message_col);
 assign active=panel||strip;
 assign rgb=panel?(panel_ink?text_color:24'h101010):(message_ink?24'h66ddff:24'h101010);
endmodule

// key_debounce - debounce a mechanical key and emit a 1-cycle press pulse.
// Board keys are active-low with external pull-ups: idle = 1, pressed = 0.
// key_press is a single-cycle pulse on the falling (press) edge of the debounced
// level. The raw input is double-registered to avoid metastability, then must
// hold a new value for DEBOUNCE_CNT consecutive cycles before it is accepted.
module key_debounce #(
    parameter DEBOUNCE_CNT = 500000   // 10 ms @ 50 MHz
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key,          // active-low, pressed = 0
    output wire key_press     // 1-cycle pulse on debounced press
);
    reg        key_r0, key_r1;      // 2-stage synchronizer
    reg        key_stable;          // debounced level
    reg [19:0] cnt;
    reg        key_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_r0     <= 1'b1;
            key_r1     <= 1'b1;
            key_stable <= 1'b1;
            cnt        <= 20'd0;
            key_prev   <= 1'b1;
        end
        else begin
            key_r0 <= key;
            key_r1 <= key_r0;

            if (key_r1 != key_stable) begin
                if (cnt >= DEBOUNCE_CNT) begin
                    key_stable <= key_r1;
                    cnt        <= 20'd0;
                end
                else begin
                    cnt <= cnt + 1'b1;
                end
            end
            else begin
                cnt <= 20'd0;
            end

            key_prev <= key_stable;
        end
    end

    assign key_press = key_prev & ~key_stable;   // falling edge = press

endmodule

// image_controller - picks which image to display and requests (re)loads.
// The TF card holds NUM_IMAGES images back-to-back, each in its own
// IMG_STRIDE_SECTORS-sector slot (image i starts at sector i*IMG_STRIDE_SECTORS).
// On boot the controller requests image 0; each debounced KEY press advances to
// the next image (wrapping) and requests a reload.
//
// Handshake with sd_loader:
//   load_req    = level, high while a (re)load is wanted
//   base_sector = frozen sector of the requested image; stable while load_req=1
//   load_ack    = 1-cycle pulse from the loader when it latched base_sector
module image_controller #(
    parameter NUM_IMAGES         = 3,     // display only the first three photo slots
    parameter IMG_STRIDE_SECTORS = 512    // 256 KiB photo slots
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sd_init_done,
    input  wire        key_press,      // debounced 1-cycle pulse
    input  wire        previous_press,
    input  wire        load_ack,       // loader latched base_sector, started
    output reg         load_req,       // level request
    output reg  [31:0] base_sector,    // frozen sector base for the requested image
    output reg         switch_event    // 1-cycle pulse for an accepted KEY2 press
);
    reg [7:0] image_index;             // 0 .. NUM_IMAGES-1
    reg       booted;

    wire [7:0] next_index = (image_index == (NUM_IMAGES - 1))
                            ? 8'd0 : image_index + 1'b1;
    wire [7:0] selected_index=previous_press ?
        ((image_index==0)?NUM_IMAGES-1:image_index-1'b1) : next_index;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            image_index <= 8'd0;
            booted      <= 1'b0;
            load_req    <= 1'b0;
            base_sector <= 32'd0;
            switch_event <= 1'b0;
        end
        else begin
            switch_event <= 1'b0;
            // ack first: the loader consumed the current request
            if (load_ack)
                load_req <= 1'b0;

            // boot: request image 0 once the SD controller is initialized
            if (!booted && sd_init_done) begin
                booted      <= 1'b1;
                image_index <= 8'd0;
                base_sector <= 32'd0;
                load_req    <= 1'b1;
            end

            // key press: advance to the next image and request a reload
            // (written last so a press in the same cycle as load_ack still wins)
            if ((key_press || previous_press) && booted) begin
                image_index <= selected_index;
                base_sector <= selected_index * IMG_STRIDE_SECTORS;
                load_req    <= 1'b1;
                switch_event <= 1'b1;
            end
        end
    end

endmodule

// Photo ping-pong control. Preload the inactive buffer without blanking, then
// pan both complete images left for 90 refreshes (~1.512 seconds at 25 MHz).
module photo_slide #(parameter AUTO_INTERVAL_CYCLES=150000000) (
    input wire clk,rst_n,vblank,loaded,next_press,previous_press,
    output reg next_load,previous_load,
    output reg [9:0] offset,
    output reg front,valid,
    output wire write_bank,
    input wire auto_enable
);
    reg [2:0] blank_sync;
    reg [1:0] phase;
    reg [6:0] frame_count,error_acc;
    // 3 s at 50 MHz, measured between accepted navigation requests.
    // Count through loading/animation; saturate if the card takes longer.
    reg [27:0] auto_count;
    wire auto_due=auto_enable&&(auto_count==AUTO_INTERVAL_CYCLES-1);
    wire tick=blank_sync[1]&&!blank_sync[2];
    wire [3:0] step=(error_acc>=80)?4'd8:4'd7;
    assign write_bank=valid?~front:1'b0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            blank_sync<=0;phase<=0;frame_count<=0;error_acc<=0;
            next_load<=0;previous_load<=0;offset<=0;front<=0;valid<=0;
            auto_count<=0;
        end else begin
            blank_sync<={blank_sync[1:0],vblank};next_load<=0;previous_load<=0;
            if(!auto_enable||!valid) auto_count<=0;
            else if(!auto_due) auto_count<=auto_count+1'b1;
            if(!valid) begin
                if(loaded&&tick) valid<=1;
            end else case(phase)
                0: if(loaded&&(next_press||previous_press||auto_due)) begin
                    previous_load<=previous_press;next_load<=!previous_press;
                    phase<=1;auto_count<=0;
                end
                1: if(!loaded) phase<=2;
                2: if(loaded) begin phase<=3;frame_count<=0;error_acc<=0;end
                3: if(tick) begin
                    error_acc<=(error_acc>=80)?error_acc-80:error_acc+10;
                    if(frame_count==89) begin
                        // old+640 == new+0: change ownership without a visible jump.
                        offset<=0;front<=~front;phase<=0;
                    end else begin
                        offset<=offset+step;frame_count<=frame_count+1'b1;
                    end
                end
                default: begin phase<=0;offset<=0;end
            endcase
        end
    end
endmodule

// Historical curtain unit retained for its regression; not instantiated by top.
// Photo-only black curtain. 45 refreshes close + 45 open = 1.512 s at 25 MHz.
// The single framebuffer is overwritten only while fully covered. SD latency
// is a separate fully-covered hold. New navigation presses while busy are ignored.
module photo_curtain (
    input wire clk,rst_n,vblank,loaded,next_press,previous_press,
    output reg next_load,previous_load,
    output reg [9:0] width
);
    reg [2:0] blank_sync;
    reg [2:0] phase;
    reg [5:0] frame_count,error_acc;
    reg direction;
    wire tick=blank_sync[1]&&!blank_sync[2];
    wire [4:0] step=(error_acc>=35)?5'd15:5'd14;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            blank_sync<=0;phase<=0;frame_count<=0;error_acc<=0;
            direction<=0;next_load<=0;previous_load<=0;width<=0;
        end else begin
            blank_sync<={blank_sync[1:0],vblank};next_load<=0;previous_load<=0;
            case(phase)
                0: if(loaded&&(next_press||previous_press)) begin
                    direction<=previous_press;phase<=1;frame_count<=0;error_acc<=0;
                end
                1: if(tick) begin
                    width<=width+step;
                    error_acc<=(error_acc>=35)?error_acc-35:error_acc+10;
                    if(frame_count==44) begin
                        width<=640;phase<=2;
                        previous_load<=direction;next_load<=!direction;
                    end else frame_count<=frame_count+1'b1;
                end
                2: if(!loaded) phase<=3;
                3: if(loaded) begin phase<=4;frame_count<=0;error_acc<=0;end
                4: if(tick) begin
                    width<=width-step;
                    error_acc<=(error_acc>=35)?error_acc-35:error_acc+10;
                    if(frame_count==44) begin width<=0;phase<=0;end
                    else frame_count<=frame_count+1'b1;
                end
                default: begin phase<=0;width<=0;end
            endcase
        end
    end
endmodule

// hdmi_switch_tone - continuously supplies a 48 kHz stereo PCM stream.
// A KEY2 event inserts 880 Hz for 80 ms followed by 1320 Hz for 100 ms. At all
// other times it supplies zero samples. The sample clock is made by a fractional
// accumulator from 50 MHz, so no extra PLL is required.
module hdmi_switch_tone (
    input  wire clk,
    input  wire rst_n,
    input  wire trigger,
    output wire audio_clk,
    output wire sample_tick,
    output wire [31:0] audio_sample_word
);
    localparam [31:0] AUDIO_PHASE_INC = 32'd4123169;
    localparam [31:0] NOTE0_PHASE_INC = 32'd78741067;
    localparam [31:0] NOTE1_PHASE_INC = 32'd118111601;
    localparam [12:0] NOTE0_SAMPLES   = 13'd3840;
    localparam [12:0] NOTE1_SAMPLES   = 13'd4800;

    reg [31:0] audio_phase;
    reg [31:0] tone_phase;
    reg [12:0] sample_count;
    reg signed [15:0] pcm_sample;
    reg        busy;
    reg        note;

    wire [31:0] audio_phase_next = audio_phase + AUDIO_PHASE_INC;
    assign sample_tick = audio_phase[31] && !audio_phase_next[31];
    wire [31:0] tone_inc = note ? NOTE1_PHASE_INC : NOTE0_PHASE_INC;
    wire [12:0] note_samples = note ? NOTE1_SAMPLES : NOTE0_SAMPLES;

    assign audio_clk = audio_phase[31];
    assign audio_sample_word = {pcm_sample, pcm_sample};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_phase  <= 32'd0;
            tone_phase   <= 32'd0;
            sample_count <= 13'd0;
            pcm_sample   <= 16'sd0;
            busy     <= 1'b0;
            note     <= 1'b0;
        end
        else begin
            audio_phase <= audio_phase_next;

            if (trigger) begin
                busy         <= 1'b1;
                note         <= 1'b0;
                tone_phase   <= 32'd0;
                sample_count <= 13'd0;
            end

            if (sample_tick) begin
                if (busy) begin
                    tone_phase <= tone_phase + tone_inc;
                    pcm_sample <= tone_phase[31] ? -16'sd8192 : 16'sd8192;

                    if (sample_count == (note_samples - 1'b1)) begin
                        sample_count <= 13'd0;
                        tone_phase   <= 32'd0;
                        if (!note)
                            note <= 1'b1;
                        else begin
                            note       <= 1'b0;
                            busy       <= 1'b0;
                            pcm_sample <= 16'sd0;
                        end
                    end
                    else begin
                        sample_count <= sample_count + 1'b1;
                    end
                end
                else begin
                    pcm_sample <= 16'sd0;
                end
            end
        end
    end

endmodule

// HDMI implementation is merged here so TD does not need new .al entries.
// The upstream MIT license is in hdmi_audio/LICENSE.txt.
// ===== merged from audio_clock_regeneration_packet.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module audio_clock_regeneration_packet (
	clk_pixel,
	clk_audio,
	clk_audio_counter_wrap,
	header,
	sub
);
	parameter real VIDEO_RATE = 25.2E6;
	parameter signed [31:0] AUDIO_RATE = 48e3;
	input wire clk_pixel;
	input wire clk_audio;
	output reg clk_audio_counter_wrap = 0;
	output wire [23:0] header;
	output wire [223:0] sub;
	function automatic signed [19:0] sv2v_cast_20_signed;
		input reg signed [19:0] inp;
		sv2v_cast_20_signed = inp;
	endfunction
	localparam [19:0] N = ((AUDIO_RATE % 125) == 0 ? sv2v_cast_20_signed((16 * AUDIO_RATE) / 125) : ((AUDIO_RATE % 225) == 0 ? sv2v_cast_20_signed((196 * AUDIO_RATE) / 225) : sv2v_cast_20_signed((AUDIO_RATE * 16) / 125)));
	localparam signed [31:0] CLK_AUDIO_COUNTER_WIDTH = $clog2(N / 128);
	function automatic [CLK_AUDIO_COUNTER_WIDTH - 1:0] sv2v_cast_C773D;
		input reg [CLK_AUDIO_COUNTER_WIDTH - 1:0] inp;
		sv2v_cast_C773D = inp;
	endfunction
	localparam [CLK_AUDIO_COUNTER_WIDTH - 1:0] CLK_AUDIO_COUNTER_END = sv2v_cast_C773D((N / 128) - 1);
	function automatic signed [CLK_AUDIO_COUNTER_WIDTH - 1:0] sv2v_cast_C773D_signed;
		input reg signed [CLK_AUDIO_COUNTER_WIDTH - 1:0] inp;
		sv2v_cast_C773D_signed = inp;
	endfunction
	reg [CLK_AUDIO_COUNTER_WIDTH - 1:0] clk_audio_counter = sv2v_cast_C773D_signed(0);
	reg internal_clk_audio_counter_wrap = 1'd0;
	always @(posedge clk_audio)
		if (clk_audio_counter == CLK_AUDIO_COUNTER_END) begin
			clk_audio_counter <= sv2v_cast_C773D_signed(0);
			internal_clk_audio_counter_wrap <= !internal_clk_audio_counter_wrap;
		end
		else
			clk_audio_counter <= clk_audio_counter + 1'd1;
	reg [1:0] clk_audio_counter_wrap_synchronizer_chain = 2'd0;
	always @(posedge clk_pixel) clk_audio_counter_wrap_synchronizer_chain <= {internal_clk_audio_counter_wrap, clk_audio_counter_wrap_synchronizer_chain[1]};
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	localparam [19:0] CYCLE_TIME_STAMP_COUNTER_IDEAL = sv2v_cast_20_signed(sv2v_cast_32_signed(((VIDEO_RATE * sv2v_cast_32_signed(N)) / 128) / AUDIO_RATE));
	localparam real tmp_f = CYCLE_TIME_STAMP_COUNTER_IDEAL;
	localparam signed [31:0] CYCLE_TIME_STAMP_COUNTER_WIDTH = $clog2(sv2v_cast_20_signed(sv2v_cast_32_signed(tmp_f * 1.1)));
	reg [19:0] cycle_time_stamp = 20'd0;
	function automatic signed [CYCLE_TIME_STAMP_COUNTER_WIDTH - 1:0] sv2v_cast_CB977_signed;
		input reg signed [CYCLE_TIME_STAMP_COUNTER_WIDTH - 1:0] inp;
		sv2v_cast_CB977_signed = inp;
	endfunction
	reg [CYCLE_TIME_STAMP_COUNTER_WIDTH - 1:0] cycle_time_stamp_counter = sv2v_cast_CB977_signed(0);
	function automatic signed [(20 - CYCLE_TIME_STAMP_COUNTER_WIDTH) - 1:0] sv2v_cast_3BF55_signed;
		input reg signed [(20 - CYCLE_TIME_STAMP_COUNTER_WIDTH) - 1:0] inp;
		sv2v_cast_3BF55_signed = inp;
	endfunction
	always @(posedge clk_pixel)
		if (clk_audio_counter_wrap_synchronizer_chain[1] ^ clk_audio_counter_wrap_synchronizer_chain[0]) begin
			cycle_time_stamp_counter <= sv2v_cast_CB977_signed(0);
			cycle_time_stamp <= {sv2v_cast_3BF55_signed(0), cycle_time_stamp_counter + sv2v_cast_CB977_signed(1)};
			clk_audio_counter_wrap <= !clk_audio_counter_wrap;
		end
		else
			cycle_time_stamp_counter <= cycle_time_stamp_counter + sv2v_cast_CB977_signed(1);
	assign header = 24'h000001;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < 4; _gv_i_1 = _gv_i_1 + 1) begin : same_packet
			localparam i = _gv_i_1;
			assign sub[i * 56+:56] = {N[7:0], N[15:8], 4'd0, N[19:16], cycle_time_stamp[7:0], cycle_time_stamp[15:8], 4'd0, cycle_time_stamp[19:16], 8'd0};
		end
	endgenerate
endmodule


// ===== merged from audio_info_frame.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module audio_info_frame (
	header,
	sub
);
	parameter [2:0] AUDIO_CHANNEL_COUNT = 3'd1;
	parameter [7:0] CHANNEL_ALLOCATION = 8'h00;
	parameter [0:0] DOWN_MIX_INHIBITED = 1'b0;
	parameter [3:0] LEVEL_SHIFT_VALUE = 4'd0;
	parameter [1:0] LOW_FREQUENCY_EFFECTS_PLAYBACK_LEVEL = 2'b00;
	output wire [23:0] header;
	output wire [223:0] sub;
	localparam [3:0] AUDIO_CODING_TYPE = 4'd0;
	localparam [2:0] SAMPLING_FREQUENCY = 3'd0;
	localparam [1:0] SAMPLE_SIZE = 2'd0;
	localparam [4:0] LENGTH = 5'd10;
	localparam [7:0] VERSION = 8'd1;
	localparam [6:0] TYPE = 7'd4;
	assign header = {3'b000, LENGTH, VERSION, 1'b1, TYPE};
	wire [7:0] packet_bytes [27:0];
	assign packet_bytes[0] = 8'd1 + ~(((((((header[23:16] + header[15:8]) + header[7:0]) + packet_bytes[5]) + packet_bytes[4]) + packet_bytes[3]) + packet_bytes[2]) + packet_bytes[1]);
	assign packet_bytes[1] = {AUDIO_CODING_TYPE, 1'b0, AUDIO_CHANNEL_COUNT};
	assign packet_bytes[2] = {3'd0, SAMPLING_FREQUENCY, SAMPLE_SIZE};
	assign packet_bytes[3] = 8'd0;
	assign packet_bytes[4] = CHANNEL_ALLOCATION;
	assign packet_bytes[5] = {DOWN_MIX_INHIBITED, LEVEL_SHIFT_VALUE, 1'b0, LOW_FREQUENCY_EFFECTS_PLAYBACK_LEVEL};
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 6; _gv_i_1 < 28; _gv_i_1 = _gv_i_1 + 1) begin : pb_reserved
			localparam i = _gv_i_1;
			assign packet_bytes[i] = 8'd0;
		end
		for (_gv_i_1 = 0; _gv_i_1 < 4; _gv_i_1 = _gv_i_1 + 1) begin : pb_to_sub
			localparam i = _gv_i_1;
			assign sub[i * 56+:56] = {packet_bytes[6 + (i * 7)], packet_bytes[5 + (i * 7)], packet_bytes[4 + (i * 7)], packet_bytes[3 + (i * 7)], packet_bytes[2 + (i * 7)], packet_bytes[1 + (i * 7)], packet_bytes[0 + (i * 7)]};
		end
	endgenerate
endmodule


// ===== merged from audio_sample_packet.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module audio_sample_packet (
	frame_counter,
	valid_bit,
	user_data_bit,
	audio_sample_word,
	audio_sample_word_present,
	header,
	sub
);
	reg _sv2v_0;
	parameter [0:0] GRADE = 1'b0;
	parameter [0:0] SAMPLE_WORD_TYPE = 1'b0;
	parameter [0:0] COPYRIGHT_NOT_ASSERTED = 1'b1;
	parameter [2:0] PRE_EMPHASIS = 3'b000;
	parameter [1:0] MODE = 2'b00;
	parameter [7:0] CATEGORY_CODE = 8'd0;
	parameter [3:0] SOURCE_NUMBER = 4'd0;
	parameter [3:0] SAMPLING_FREQUENCY = 4'b0000;
	parameter [1:0] CLOCK_ACCURACY = 2'b00;
	parameter [3:0] WORD_LENGTH = 0;
	parameter [3:0] ORIGINAL_SAMPLING_FREQUENCY = 4'b0000;
	parameter [0:0] LAYOUT = 1'b0;
	input wire [7:0] frame_counter;
	input wire [7:0] valid_bit;
	input wire [7:0] user_data_bit;
	input wire [191:0] audio_sample_word;
	input wire [3:0] audio_sample_word_present;
	output wire [23:0] header;
	output reg [223:0] sub;
	reg [3:0] CHANNEL_LEFT = 4'd1;
	reg [3:0] CHANNEL_RIGHT = 4'd2;
	localparam [7:0] CHANNEL_STATUS_LENGTH = 8'd192;
	wire [191:0] channel_status_left;
	assign channel_status_left = {152'd0, ORIGINAL_SAMPLING_FREQUENCY, WORD_LENGTH, 2'b00, CLOCK_ACCURACY, SAMPLING_FREQUENCY, CHANNEL_LEFT, SOURCE_NUMBER, CATEGORY_CODE, MODE, PRE_EMPHASIS, COPYRIGHT_NOT_ASSERTED, SAMPLE_WORD_TYPE, GRADE};
	wire [CHANNEL_STATUS_LENGTH - 1:0] channel_status_right;
	assign channel_status_right = {152'd0, ORIGINAL_SAMPLING_FREQUENCY, WORD_LENGTH, 2'b00, CLOCK_ACCURACY, SAMPLING_FREQUENCY, CHANNEL_RIGHT, SOURCE_NUMBER, CATEGORY_CODE, MODE, PRE_EMPHASIS, COPYRIGHT_NOT_ASSERTED, SAMPLE_WORD_TYPE, GRADE};
	assign header[19:12] = {7'b0000000, LAYOUT};
	assign header[7:0] = 8'd2;
	wire [1:0] parity_bit [3:0];
	reg [7:0] aligned_frame_counter [3:0];
	genvar _gv_i_1;
	function automatic [7:0] sv2v_cast_8;
		input reg [7:0] inp;
		sv2v_cast_8 = inp;
	endfunction
	generate
		for (_gv_i_1 = 0; _gv_i_1 < 4; _gv_i_1 = _gv_i_1 + 1) begin : sample_based_assign
			localparam i = _gv_i_1;
			always @(*) begin
				if (_sv2v_0)
					;
				if (sv2v_cast_8(frame_counter + i) >= CHANNEL_STATUS_LENGTH)
					aligned_frame_counter[i] = sv2v_cast_8((frame_counter + i) - CHANNEL_STATUS_LENGTH);
				else
					aligned_frame_counter[i] = sv2v_cast_8(frame_counter + i);
			end
			assign header[20 + i] = (aligned_frame_counter[i] == 8'd0) && audio_sample_word_present[i];
			assign header[8 + i] = audio_sample_word_present[i];
			assign parity_bit[i][0] = ^{channel_status_left[aligned_frame_counter[i]], user_data_bit[i * 2], valid_bit[i * 2], audio_sample_word[(i * 2) * 24+:24]};
			assign parity_bit[i][1] = ^{channel_status_right[aligned_frame_counter[i]], user_data_bit[(i * 2) + 1], valid_bit[(i * 2) + 1], audio_sample_word[((i * 2) + 1) * 24+:24]};
			always @(*) begin
				if (_sv2v_0)
					;
				if (audio_sample_word_present[i])
					sub[i * 56+:56] = {parity_bit[i][1], channel_status_right[aligned_frame_counter[i]], user_data_bit[(i * 2) + 1], valid_bit[(i * 2) + 1], parity_bit[i][0], channel_status_left[aligned_frame_counter[i]], user_data_bit[i * 2], valid_bit[i * 2], audio_sample_word[((i * 2) + 1) * 24+:24], audio_sample_word[(i * 2) * 24+:24]};
				else
					sub[i * 56+:56] = 56'bxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx;
			end
		end
	endgenerate
	initial _sv2v_0 = 0;
endmodule


// ===== merged from auxiliary_video_information_info_frame.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module auxiliary_video_information_info_frame (
	header,
	sub
);
	parameter [1:0] VIDEO_FORMAT = 2'b00;
	parameter [0:0] ACTIVE_FORMAT_INFO_PRESENT = 1'b0;
	parameter [1:0] BAR_INFO = 2'b00;
	parameter [1:0] SCAN_INFO = 2'b00;
	parameter [1:0] COLORIMETRY = 2'b00;
	parameter [1:0] PICTURE_ASPECT_RATIO = 2'b00;
	parameter [3:0] ACTIVE_FORMAT_ASPECT_RATIO = 4'b1000;
	parameter [0:0] IT_CONTENT = 1'b0;
	parameter [2:0] EXTENDED_COLORIMETRY = 3'b000;
	parameter [1:0] RGB_QUANTIZATION_RANGE = 2'b00;
	parameter [1:0] NON_UNIFORM_PICTURE_SCALING = 2'b00;
	parameter signed [31:0] VIDEO_ID_CODE = 4;
	parameter [1:0] YCC_QUANTIZATION_RANGE = 2'b00;
	parameter [1:0] CONTENT_TYPE = 2'b00;
	parameter [3:0] PIXEL_REPETITION = 4'b0000;
	output wire [23:0] header;
	output wire [223:0] sub;
	localparam [4:0] LENGTH = 5'd13;
	localparam [7:0] VERSION = 8'd2;
	localparam [6:0] TYPE = 7'd2;
	assign header = {3'b000, LENGTH, VERSION, 1'b1, TYPE};
	wire [7:0] packet_bytes [27:0];
	assign packet_bytes[0] = 8'd1 + ~(((((((((((((((header[23:16] + header[15:8]) + header[7:0]) + packet_bytes[13]) + packet_bytes[12]) + packet_bytes[11]) + packet_bytes[10]) + packet_bytes[9]) + packet_bytes[8]) + packet_bytes[7]) + packet_bytes[6]) + packet_bytes[5]) + packet_bytes[4]) + packet_bytes[3]) + packet_bytes[2]) + packet_bytes[1]);
	assign packet_bytes[1] = {1'b0, VIDEO_FORMAT, ACTIVE_FORMAT_INFO_PRESENT, BAR_INFO, SCAN_INFO};
	assign packet_bytes[2] = {COLORIMETRY, PICTURE_ASPECT_RATIO, ACTIVE_FORMAT_ASPECT_RATIO};
	assign packet_bytes[3] = {IT_CONTENT, EXTENDED_COLORIMETRY, RGB_QUANTIZATION_RANGE, NON_UNIFORM_PICTURE_SCALING};
	function automatic signed [6:0] sv2v_cast_7_signed;
		input reg signed [6:0] inp;
		sv2v_cast_7_signed = inp;
	endfunction
	assign packet_bytes[4] = {1'b0, sv2v_cast_7_signed(VIDEO_ID_CODE)};
	assign packet_bytes[5] = {YCC_QUANTIZATION_RANGE, CONTENT_TYPE, PIXEL_REPETITION};
	genvar _gv_i_1;
	generate
		if (BAR_INFO != 2'b00) begin : genblk1
			assign packet_bytes[6] = 8'hff;
			assign packet_bytes[7] = 8'hff;
			assign packet_bytes[8] = 8'h00;
			assign packet_bytes[9] = 8'h00;
			assign packet_bytes[10] = 8'hff;
			assign packet_bytes[11] = 8'hff;
			assign packet_bytes[12] = 8'h00;
			assign packet_bytes[13] = 8'h00;
		end
		else begin : genblk1
			assign packet_bytes[6] = 8'h00;
			assign packet_bytes[7] = 8'h00;
			assign packet_bytes[8] = 8'h00;
			assign packet_bytes[9] = 8'h00;
			assign packet_bytes[10] = 8'h00;
			assign packet_bytes[11] = 8'h00;
			assign packet_bytes[12] = 8'h00;
			assign packet_bytes[13] = 8'h00;
		end
		for (_gv_i_1 = 14; _gv_i_1 < 28; _gv_i_1 = _gv_i_1 + 1) begin : pb_reserved
			localparam i = _gv_i_1;
			assign packet_bytes[i] = 8'd0;
		end
		for (_gv_i_1 = 0; _gv_i_1 < 4; _gv_i_1 = _gv_i_1 + 1) begin : pb_to_sub
			localparam i = _gv_i_1;
			assign sub[i * 56+:56] = {packet_bytes[6 + (i * 7)], packet_bytes[5 + (i * 7)], packet_bytes[4 + (i * 7)], packet_bytes[3 + (i * 7)], packet_bytes[2 + (i * 7)], packet_bytes[1 + (i * 7)], packet_bytes[0 + (i * 7)]};
		end
	endgenerate
endmodule


// ===== merged from packet_assembler.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module packet_assembler (
	clk_pixel,
	reset,
	data_island_period,
	header,
	sub,
	packet_data,
	counter
);
	input wire clk_pixel;
	input wire reset;
	input wire data_island_period;
	input wire [23:0] header;
	input wire [223:0] sub;
	output wire [8:0] packet_data;
	output reg [4:0] counter = 5'd0;
	always @(posedge clk_pixel)
		if (reset)
			counter <= 5'd0;
		else if (data_island_period)
			counter <= counter + 5'd1;
	wire [5:0] counter_t2 = {counter, 1'b0};
	wire [5:0] counter_t2_p1 = {counter, 1'b1};
	reg [39:0] parity = 40'h0000000000;
	wire [63:0] bch [3:0];
	assign bch[0] = {parity[0+:8], sub[0+:56]};
	assign bch[1] = {parity[8+:8], sub[56+:56]};
	assign bch[2] = {parity[16+:8], sub[112+:56]};
	assign bch[3] = {parity[24+:8], sub[168+:56]};
	wire [31:0] bch4 = {parity[32+:8], header};
	assign packet_data = {bch[3][counter_t2_p1], bch[2][counter_t2_p1], bch[1][counter_t2_p1], bch[0][counter_t2_p1], bch[3][counter_t2], bch[2][counter_t2], bch[1][counter_t2], bch[0][counter_t2], bch4[counter]};
	function automatic [7:0] next_ecc;
		input [7:0] ecc;
		input [7:0] next_bch_bit;
		next_ecc = (ecc >> 1) ^ (ecc[0] ^ next_bch_bit ? 8'b10000011 : 8'd0);
	endfunction
	wire [7:0] parity_next [4:0];
	wire [31:0] parity_next_next;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < 5; _gv_i_1 = _gv_i_1 + 1) begin : parity_calc
			localparam i = _gv_i_1;
			if (i == 4) begin : genblk1
				assign parity_next[i] = next_ecc(parity[i * 8+:8], header[counter]);
			end
			else begin : genblk1
				assign parity_next[i] = next_ecc(parity[i * 8+:8], sub[(i * 56) + counter_t2]);
				assign parity_next_next[i * 8+:8] = next_ecc(parity_next[i], sub[(i * 56) + counter_t2_p1]);
			end
		end
	endgenerate
	always @(posedge clk_pixel)
		if (reset)
			parity <= 40'h0000000000;
		else if (data_island_period) begin
			if (counter < 5'd28) begin
				parity[0+:32] <= parity_next_next;
				if (counter < 5'd24)
					parity[32+:8] <= parity_next[4];
			end
			else if (counter == 5'd31)
				parity <= 40'h0000000000;
		end
		else
			parity <= 40'h0000000000;
endmodule


// ===== merged from packet_picker.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module packet_picker (
	clk_pixel,
	clk_audio,
	reset,
	video_field_end,
	packet_enable,
	packet_pixel_counter,
	audio_sample_word,
	header,
	sub
);
	reg _sv2v_0;
	parameter signed [31:0] VIDEO_ID_CODE = 4;
	parameter real VIDEO_RATE = 0;
	parameter [0:0] IT_CONTENT = 1'b0;
	parameter signed [31:0] AUDIO_BIT_WIDTH = 0;
	parameter signed [31:0] AUDIO_RATE = 0;
	parameter [63:0] VENDOR_NAME = 0;
	parameter [127:0] PRODUCT_DESCRIPTION = 0;
	parameter [7:0] SOURCE_DEVICE_INFORMATION = 0;
	input wire clk_pixel;
	input wire clk_audio;
	input wire reset;
	input wire video_field_end;
	input wire packet_enable;
	input wire [4:0] packet_pixel_counter;
	input wire [(2 * AUDIO_BIT_WIDTH) - 1:0] audio_sample_word;
	output wire [23:0] header;
	output wire [223:0] sub;
	reg [7:0] packet_type = 8'd0;
    // Only five packet types carry payload. Avoid sparse 256-entry arrays
    // with 250 undriven entries and a 248-bit variable-index multiplexer.
    wire [23:0] header_acr, header_audio, header_avi, header_spd, header_aif;
    wire [223:0] sub_acr, sub_audio, sub_avi, sub_spd, sub_aif;
    reg [23:0] selected_header;
    reg [223:0] selected_sub;
    assign header = selected_header;
    assign sub = selected_sub;
    always @(*) begin
        selected_header = 24'd0;
        selected_sub = 224'd0;
        case (packet_type)
            8'h01: begin selected_header = header_acr;   selected_sub = sub_acr;   end
            8'h02: begin selected_header = header_audio; selected_sub = sub_audio; end
            8'h82: begin selected_header = header_avi;   selected_sub = sub_avi;   end
            8'h83: begin selected_header = header_spd;   selected_sub = sub_spd;   end
            8'h84: begin selected_header = header_aif;   selected_sub = sub_aif;   end
            default: begin end // HDMI Null packet: all bytes zero.
        endcase
    end
	wire clk_audio_counter_wrap;
	audio_clock_regeneration_packet #(
		.VIDEO_RATE(VIDEO_RATE),
		.AUDIO_RATE(AUDIO_RATE)
	) audio_clock_regeneration_packet(
		.clk_pixel(clk_pixel),
		.clk_audio(clk_audio),
		.clk_audio_counter_wrap(clk_audio_counter_wrap),
		.header(header_acr),
		.sub(sub_acr)
	);
	localparam [3:0] SAMPLING_FREQUENCY = (AUDIO_RATE == 32000 ? 4'b0011 : (AUDIO_RATE == 44100 ? 4'b0000 : (AUDIO_RATE == 88200 ? 4'b1000 : (AUDIO_RATE == 176400 ? 4'b1100 : (AUDIO_RATE == 48000 ? 4'b0010 : (AUDIO_RATE == 96000 ? 4'b1010 : (AUDIO_RATE == 192000 ? 4'b1110 : 4'bxxxx)))))));
	localparam signed [31:0] AUDIO_BIT_WIDTH_COMPARATOR = (AUDIO_BIT_WIDTH < 20 ? 20 : (AUDIO_BIT_WIDTH == 20 ? 25 : (AUDIO_BIT_WIDTH < 24 ? 24 : (AUDIO_BIT_WIDTH == 24 ? 29 : -1))));
	function automatic signed [2:0] sv2v_cast_3_signed;
		input reg signed [2:0] inp;
		sv2v_cast_3_signed = inp;
	endfunction
	localparam [2:0] WORD_LENGTH = sv2v_cast_3_signed(AUDIO_BIT_WIDTH_COMPARATOR - AUDIO_BIT_WIDTH);
	localparam [0:0] WORD_LENGTH_LIMIT = (AUDIO_BIT_WIDTH <= 20 ? 1'b0 : 1'b1);
	reg [(2 * AUDIO_BIT_WIDTH) - 1:0] audio_sample_word_transfer;
	reg audio_sample_word_transfer_control = 1'd0;
	always @(posedge clk_audio) begin
		audio_sample_word_transfer <= audio_sample_word;
		audio_sample_word_transfer_control <= !audio_sample_word_transfer_control;
	end
	// Never edge-detect the first (potentially metastable) synchronizer stage.
	reg [2:0] audio_sample_word_transfer_control_synchronizer_chain = 3'd0;
	always @(posedge clk_pixel) audio_sample_word_transfer_control_synchronizer_chain <= {audio_sample_word_transfer_control_synchronizer_chain[1:0], audio_sample_word_transfer_control};
	reg sample_buffer_current = 1'b0;
	reg [1:0] samples_remaining = 2'd0;
	reg [191:0] audio_sample_word_buffer [1:0];
    wire sample_arrived = audio_sample_word_transfer_control_synchronizer_chain[2] ^
                          audio_sample_word_transfer_control_synchronizer_chain[1];
    wire [47:0] sample_pair = {
        audio_sample_word_transfer[AUDIO_BIT_WIDTH+:AUDIO_BIT_WIDTH],
        {(24-AUDIO_BIT_WIDTH){1'b0}},
        audio_sample_word_transfer[0+:AUDIO_BIT_WIDTH],
        {(24-AUDIO_BIT_WIDTH){1'b0}}
    };
    reg sample_buffer_used = 1'b0;
    reg sample_buffer_ready = 1'b0;
    genvar audio_bank, audio_slot;
    generate
        for (audio_bank=0; audio_bank<2; audio_bank=audio_bank+1) begin : audio_banks
            for (audio_slot=0; audio_slot<4; audio_slot=audio_slot+1) begin : audio_slots
                always @(posedge clk_pixel) begin
                    if (reset)
                        audio_sample_word_buffer[audio_bank][audio_slot*48+:48] <= 48'd0;
                    else if (sample_arrived && (sample_buffer_current == audio_bank) &&
                             (samples_remaining == audio_slot))
                        audio_sample_word_buffer[audio_bank][audio_slot*48+:48] <= sample_pair;
                end
            end
        end
    endgenerate
    always @(posedge clk_pixel) begin
        if (reset) begin
            sample_buffer_current <= 1'b0;
            samples_remaining <= 2'd0;
            sample_buffer_ready <= 1'b0;
        end else begin
            if (sample_buffer_used) sample_buffer_ready <= 1'b0;
            if (sample_arrived) begin
                if (samples_remaining == 2'd3) begin
                    samples_remaining <= 2'd0;
                    sample_buffer_ready <= 1'b1;
                    sample_buffer_current <= !sample_buffer_current;
                end else samples_remaining <= samples_remaining + 1'b1;
            end
        end
    end
	reg [191:0] audio_sample_word_packet;
	reg [3:0] audio_sample_word_present_packet;
	reg [7:0] frame_counter = 8'd0;
	wire signed [31:0] k;
	always @(posedge clk_pixel)
		if (reset)
			frame_counter <= 8'd0;
		else if ((packet_pixel_counter == 5'd31) && (packet_type == 8'h02)) begin
			frame_counter = frame_counter + 8'd4;
			if (frame_counter >= 8'd192)
				frame_counter = frame_counter - 8'd192;
		end
	audio_sample_packet #(
		.SAMPLING_FREQUENCY(SAMPLING_FREQUENCY),
		.WORD_LENGTH({WORD_LENGTH[0], WORD_LENGTH[1], WORD_LENGTH[2], WORD_LENGTH_LIMIT})
	) audio_sample_packet(
		.frame_counter(frame_counter),
		.valid_bit(8'b00000000),
		.user_data_bit(8'b00000000),
		.audio_sample_word(audio_sample_word_packet),
		.audio_sample_word_present(audio_sample_word_present_packet),
		.header(header_audio),
		.sub(sub_audio)
	);
	function automatic signed [6:0] sv2v_cast_7_signed;
		input reg signed [6:0] inp;
		sv2v_cast_7_signed = inp;
	endfunction
	auxiliary_video_information_info_frame #(
		.VIDEO_ID_CODE(sv2v_cast_7_signed(VIDEO_ID_CODE)),
		.IT_CONTENT(IT_CONTENT)
	) auxiliary_video_information_info_frame(
		.header(header_avi),
		.sub(sub_avi)
	);
	source_product_description_info_frame #(
		.VENDOR_NAME(VENDOR_NAME),
		.PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION),
		.SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION)
	) source_product_description_info_frame(
		.header(header_spd),
		.sub(sub_spd)
	);
	audio_info_frame audio_info_frame(
		.header(header_aif),
		.sub(sub_aif)
	);
	reg audio_info_frame_sent = 1'b0;
	reg auxiliary_video_information_info_frame_sent = 1'b0;
	reg source_product_description_info_frame_sent = 1'b0;
	reg last_clk_audio_counter_wrap = 1'b0;
	always @(posedge clk_pixel) begin
		if (sample_buffer_used)
			sample_buffer_used <= 1'b0;
		if (reset || video_field_end) begin
			audio_info_frame_sent <= 1'b0;
			auxiliary_video_information_info_frame_sent <= 1'b0;
			source_product_description_info_frame_sent <= 1'b0;
			packet_type <= 8'd0;
		end
		else if (packet_enable) begin
			if (last_clk_audio_counter_wrap ^ clk_audio_counter_wrap) begin
				packet_type <= 8'd1;
				last_clk_audio_counter_wrap <= clk_audio_counter_wrap;
			end
			else if (sample_buffer_ready) begin
				packet_type <= 8'd2;
				audio_sample_word_packet <= audio_sample_word_buffer[!sample_buffer_current];
				audio_sample_word_present_packet <= 4'b1111;
				sample_buffer_used <= 1'b1;
			end
			else if (!audio_info_frame_sent) begin
				packet_type <= 8'h84;
				audio_info_frame_sent <= 1'b1;
			end
			else if (!auxiliary_video_information_info_frame_sent) begin
				packet_type <= 8'h82;
				auxiliary_video_information_info_frame_sent <= 1'b1;
			end
			else if (!source_product_description_info_frame_sent) begin
				packet_type <= 8'h83;
				source_product_description_info_frame_sent <= 1'b1;
			end
			else
				packet_type <= 8'd0;
		end
	end
	initial _sv2v_0 = 0;
endmodule


// ===== merged from source_product_description_info_frame.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module source_product_description_info_frame (
	header,
	sub
);
	parameter [63:0] VENDOR_NAME = 0;
	parameter [127:0] PRODUCT_DESCRIPTION = 0;
	parameter [7:0] SOURCE_DEVICE_INFORMATION = 0;
	output wire [23:0] header;
	output wire [223:0] sub;
	localparam [4:0] LENGTH = 5'd25;
	localparam [7:0] VERSION = 8'd1;
	localparam [6:0] TYPE = 7'd3;
	assign header = {3'b000, LENGTH, VERSION, 1'b1, TYPE};
	wire [7:0] packet_bytes [27:0];
	assign packet_bytes[0] = 8'd1 + ~((((((((((((((((((((((((((header[23:16] + header[15:8]) + header[7:0]) + packet_bytes[24]) + packet_bytes[23]) + packet_bytes[22]) + packet_bytes[21]) + packet_bytes[20]) + packet_bytes[19]) + packet_bytes[18]) + packet_bytes[17]) + packet_bytes[16]) + packet_bytes[15]) + packet_bytes[14]) + packet_bytes[13]) + packet_bytes[12]) + packet_bytes[11]) + packet_bytes[10]) + packet_bytes[9]) + packet_bytes[8]) + packet_bytes[7]) + packet_bytes[6]) + packet_bytes[5]) + packet_bytes[4]) + packet_bytes[3]) + packet_bytes[2]) + packet_bytes[1]);
	wire signed [7:0] vendor_name [0:7];
	wire signed [7:0] product_description [0:15];
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < 8; _gv_i_1 = _gv_i_1 + 1) begin : vendor_to_bytes
			localparam i = _gv_i_1;
			assign vendor_name[i] = VENDOR_NAME[((8 - i) * 8) - 1:(7 - i) * 8];
		end
		for (_gv_i_1 = 0; _gv_i_1 < 16; _gv_i_1 = _gv_i_1 + 1) begin : product_to_bytes
			localparam i = _gv_i_1;
			assign product_description[i] = PRODUCT_DESCRIPTION[((16 - i) * 8) - 1:(15 - i) * 8];
		end
		for (_gv_i_1 = 1; _gv_i_1 < 9; _gv_i_1 = _gv_i_1 + 1) begin : pb_vendor
			localparam i = _gv_i_1;
			assign packet_bytes[i] = (vendor_name[i - 1] == 8'h30 ? 8'h00 : vendor_name[i - 1]);
		end
		for (_gv_i_1 = 9; _gv_i_1 < LENGTH; _gv_i_1 = _gv_i_1 + 1) begin : pb_product
			localparam i = _gv_i_1;
			assign packet_bytes[i] = (product_description[i - 9] == 8'h30 ? 8'h00 : product_description[i - 9]);
		end
	endgenerate
	assign packet_bytes[LENGTH] = SOURCE_DEVICE_INFORMATION;
	generate
		for (_gv_i_1 = 26; _gv_i_1 < 28; _gv_i_1 = _gv_i_1 + 1) begin : pb_reserved
			localparam i = _gv_i_1;
			assign packet_bytes[i] = 8'd0;
		end
		for (_gv_i_1 = 0; _gv_i_1 < 4; _gv_i_1 = _gv_i_1 + 1) begin : pb_to_sub
			localparam i = _gv_i_1;
			assign sub[i * 56+:56] = {packet_bytes[6 + (i * 7)], packet_bytes[5 + (i * 7)], packet_bytes[4 + (i * 7)], packet_bytes[3 + (i * 7)], packet_bytes[2 + (i * 7)], packet_bytes[1 + (i * 7)], packet_bytes[0 + (i * 7)]};
		end
	endgenerate
endmodule


// ===== merged from tmds_channel.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module tmds_channel (
	clk_pixel,
	video_data,
	data_island_data,
	control_data,
	mode,
	tmds
);
	reg _sv2v_0;
	parameter signed [31:0] CN = 0;
	input wire clk_pixel;
	input wire [7:0] video_data;
	input wire [3:0] data_island_data;
	input wire [1:0] control_data;
	input wire [2:0] mode;
	output reg [9:0] tmds = 10'b1101010100;
	reg signed [4:0] acc = 5'sd0;
	reg [8:0] q_m;
	reg [9:0] q_out;
	wire [9:0] video_coding;
	assign video_coding = q_out;
	reg [3:0] N1D;
	reg signed [4:0] N1q_m07;
	reg signed [4:0] N0q_m07;
	always @(*) begin
		if (_sv2v_0)
			;
		N1D = ((((((video_data[0] + video_data[1]) + video_data[2]) + video_data[3]) + video_data[4]) + video_data[5]) + video_data[6]) + video_data[7];
		case (((((((q_m[0] + q_m[1]) + q_m[2]) + q_m[3]) + q_m[4]) + q_m[5]) + q_m[6]) + q_m[7])
			4'b0000: N1q_m07 = 5'sd0;
			4'b0001: N1q_m07 = 5'sd1;
			4'b0010: N1q_m07 = 5'sd2;
			4'b0011: N1q_m07 = 5'sd3;
			4'b0100: N1q_m07 = 5'sd4;
			4'b0101: N1q_m07 = 5'sd5;
			4'b0110: N1q_m07 = 5'sd6;
			4'b0111: N1q_m07 = 5'sd7;
			4'b1000: N1q_m07 = 5'sd8;
			default: N1q_m07 = 5'sd0;
		endcase
		N0q_m07 = 5'sd8 - N1q_m07;
	end
	reg signed [4:0] acc_add;
	integer i;
	always @(*) begin
		if (_sv2v_0)
			;
		if ((N1D > 4'd4) || ((N1D == 4'd4) && (video_data[0] == 1'd0))) begin
			q_m[0] = video_data[0];
			for (i = 0; i < 7; i = i + 1)
				q_m[i + 1] = q_m[i] ~^ video_data[i + 1];
			q_m[8] = 1'b0;
		end
		else begin
			q_m[0] = video_data[0];
			for (i = 0; i < 7; i = i + 1)
				q_m[i + 1] = q_m[i] ^ video_data[i + 1];
			q_m[8] = 1'b1;
		end
		if ((acc == 5'sd0) || (N1q_m07 == N0q_m07)) begin
			if (q_m[8]) begin
				acc_add = N1q_m07 - N0q_m07;
				q_out = {~q_m[8], q_m[8], q_m[7:0]};
			end
			else begin
				acc_add = N0q_m07 - N1q_m07;
				q_out = {~q_m[8], q_m[8], ~q_m[7:0]};
			end
		end
		else if (((acc > 5'sd0) && (N1q_m07 > N0q_m07)) || ((acc < 5'sd0) && (N1q_m07 < N0q_m07))) begin
			q_out = {1'b1, q_m[8], ~q_m[7:0]};
			acc_add = (N0q_m07 - N1q_m07) + (q_m[8] ? 5'sd2 : 5'sd0);
		end
		else begin
			q_out = {1'b0, q_m[8], q_m[7:0]};
			acc_add = (N1q_m07 - N0q_m07) - (~q_m[8] ? 5'sd2 : 5'sd0);
		end
	end
	always @(posedge clk_pixel) acc <= (mode != 3'd1 ? 5'sd0 : acc + acc_add);
	reg [9:0] control_coding;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (control_data)
			2'b00: control_coding = 10'b1101010100;
			2'b01: control_coding = 10'b0010101011;
			2'b10: control_coding = 10'b0101010100;
			2'b11: control_coding = 10'b1010101011;
		endcase
	end
	reg [9:0] terc4_coding;
	always @(*) begin
		if (_sv2v_0)
			;
		(* full_case, parallel_case *)
		case (data_island_data)
			4'b0000: terc4_coding = 10'b1010011100;
			4'b0001: terc4_coding = 10'b1001100011;
			4'b0010: terc4_coding = 10'b1011100100;
			4'b0011: terc4_coding = 10'b1011100010;
			4'b0100: terc4_coding = 10'b0101110001;
			4'b0101: terc4_coding = 10'b0100011110;
			4'b0110: terc4_coding = 10'b0110001110;
			4'b0111: terc4_coding = 10'b0100111100;
			4'b1000: terc4_coding = 10'b1011001100;
			4'b1001: terc4_coding = 10'b0100111001;
			4'b1010: terc4_coding = 10'b0110011100;
			4'b1011: terc4_coding = 10'b1011000110;
			4'b1100: terc4_coding = 10'b1010001110;
			4'b1101: terc4_coding = 10'b1001110001;
			4'b1110: terc4_coding = 10'b0101100011;
			4'b1111: terc4_coding = 10'b1011000011;
		endcase
	end
	wire [9:0] video_guard_band;
	generate
		if ((CN == 0) || (CN == 2)) begin : genblk1
			assign video_guard_band = 10'b1011001100;
		end
		else begin : genblk1
			assign video_guard_band = 10'b0100110011;
		end
	endgenerate
	wire [9:0] data_guard_band;
	generate
		if ((CN == 1) || (CN == 2)) begin : genblk2
			assign data_guard_band = 10'b0100110011;
		end
		else begin : genblk2
			assign data_guard_band = (control_data == 2'b00 ? 10'b1010001110 : (control_data == 2'b01 ? 10'b1001110001 : (control_data == 2'b10 ? 10'b0101100011 : 10'b1011000011)));
		end
	endgenerate
	always @(posedge clk_pixel)
		case (mode)
			3'd0: tmds <= control_coding;
			3'd1: tmds <= video_coding;
			3'd2: tmds <= video_guard_band;
			3'd3: tmds <= terc4_coding;
			3'd4: tmds <= data_guard_band;
		endcase
	initial _sv2v_0 = 0;
endmodule


// ===== merged from eg4_tmds_phy.vh =====
// EG4 10:1 TMDS serializer.
// Adapted from the MIT-licensed DR1 implementation in this directory's
// upstream project. EG_LOGIC_ODDR is the EG4 output DDR primitive.

module lane_lvds_10_1 (
    input  wire       I_pixel_clk,
    input  wire       I_serial_clk,
    input  wire       I_rst,
    input  wire [9:0] I_data_in,
    output wire       O_serial_out
);
    reg       odd_even;
    reg       odd_even_1d;
    reg       odd_even_2d;
    reg       load_en;
    reg       load_en_1d;
    reg       load_en_2d;
    reg [9:0] shift_data;
    reg [1:0] oddr_data;

    always @(posedge I_pixel_clk or posedge I_rst) begin
        if (I_rst)
            odd_even <= 1'b0;
        else
            odd_even <= ~odd_even;
    end

    always @(posedge I_serial_clk or posedge I_rst) begin
        if (I_rst) begin
            odd_even_1d <= 1'b0;
            odd_even_2d <= 1'b0;
            load_en     <= 1'b0;
            load_en_1d  <= 1'b0;
            load_en_2d  <= 1'b0;
        end
        else begin
            odd_even_1d <= odd_even;
            odd_even_2d <= odd_even_1d;
            load_en     <= odd_even_1d ^ odd_even_2d;
            load_en_1d  <= load_en;
            load_en_2d  <= load_en_1d;
        end
    end

    always @(posedge I_serial_clk or posedge I_rst) begin
        if (I_rst)
            shift_data <= 10'd0;
        else if (load_en_2d)
            shift_data <= I_data_in;
        else
            shift_data <= shift_data << 2;
    end

    always @(posedge I_serial_clk or posedge I_rst) begin
        if (I_rst)
            oddr_data <= 2'b00;
        else
            oddr_data <= shift_data[9:8];
    end

    EG_LOGIC_ODDR #(
        .ASYNCRST("ENABLE")
    ) u_oddr (
        .q   (O_serial_out),
        .clk (I_serial_clk),
        .d1  (oddr_data[0]),
        .d0  (oddr_data[1]),
        .rst (I_rst)
    );
endmodule

module dvi_tx_tmds_phy (
    input  wire       pixel_clock,
    input  wire       ddr_bit_clock,
    input  wire       reset,
    input  wire [9:0] data,
    output wire       tmds_lane
);
    // Reverse the vector so HDMI bit 0 leaves the pin first.
    wire [9:0] serial_data = {data[0], data[1], data[2], data[3], data[4],
                              data[5], data[6], data[7], data[8], data[9]};

    lane_lvds_10_1 u_lane (
        .I_pixel_clk  (pixel_clock),
        .I_serial_clk (ddr_bit_clock),
        .I_rst        (reset),
        .I_data_in    (serial_data),
        .O_serial_out (tmds_lane)
    );
endmodule


// ===== merged from hdmi.vh =====
// ==========================================================
//  ____         _                ____                      
// | __ )  _ __ (_)  __ _  _ __  / ___|  _   _  _ __    ___ 
// |  _ \ | '__|| | / _` || '_ \ \___ \ | | | || '_ \  / _ \
// | |_) || |   | || (_| || | | | ___) || |_| || | | ||  __/
// |____/ |_|   |_| \__,_||_| |_||____/  \__,_||_| |_| \___|
//                                                          
// ==========================================================
// Programmed By: BrianSune
// Contact: briansune@gmail.com
// ==========================================================
// 

module hdmi (
	clk_pixel_x5,
	clk_pixel,
	clk_audio,
	reset,
	rgb,
	audio_sample_word,
	tmds,
	tmds_clock,
	cx,
	cy,
	frame_width,
	frame_height,
	screen_width,
	screen_height
);
	reg _sv2v_0;
	parameter signed [31:0] VIDEO_ID_CODE = 1;
	parameter [0:0] IT_CONTENT = 1'b1;
	parameter signed [31:0] BIT_WIDTH = (VIDEO_ID_CODE < 4 ? 10 : (VIDEO_ID_CODE == 4 ? 11 : 12));
	parameter signed [31:0] BIT_HEIGHT = (VIDEO_ID_CODE == 16 ? 11 : 10);
	parameter [0:0] DVI_OUTPUT = 1'b0;
	parameter real VIDEO_REFRESH_RATE = 59.94;
	parameter signed [31:0] AUDIO_RATE = 44100;
	parameter signed [31:0] AUDIO_BIT_WIDTH = 16;
	parameter [63:0] VENDOR_NAME = {"Unknown", 8'd0};
	parameter [127:0] PRODUCT_DESCRIPTION = {"FPGA", 96'd0};
	parameter [7:0] SOURCE_DEVICE_INFORMATION = 8'h00;
	parameter signed [31:0] START_X = 0;
	parameter signed [31:0] START_Y = 0;
	input wire clk_pixel_x5;
	input wire clk_pixel;
	input wire clk_audio;
	input wire reset;
	input wire [23:0] rgb;
	input wire [(2 * AUDIO_BIT_WIDTH) - 1:0] audio_sample_word;
	output wire [2:0] tmds;
	output wire tmds_clock;
	output reg [BIT_WIDTH - 1:0] cx = START_X;
	output reg [BIT_HEIGHT - 1:0] cy = START_Y;
	output wire [BIT_WIDTH - 1:0] frame_width;
	output wire [BIT_HEIGHT - 1:0] frame_height;
	output wire [BIT_WIDTH - 1:0] screen_width;
	output wire [BIT_HEIGHT - 1:0] screen_height;
	localparam signed [31:0] NUM_CHANNELS = 3;
	reg hsync;
	reg vsync;
	wire [BIT_WIDTH - 1:0] hsync_pulse_start;
	wire [BIT_WIDTH - 1:0] hsync_pulse_size;
	wire [BIT_HEIGHT - 1:0] vsync_pulse_start;
	wire [BIT_HEIGHT - 1:0] vsync_pulse_size;
	wire invert;
	generate
		case (VIDEO_ID_CODE)
			1: begin : genblk1
				assign frame_width = 800;
				assign frame_height = 525;
				assign screen_width = 640;
				assign screen_height = 480;
				assign hsync_pulse_start = 16;
				assign hsync_pulse_size = 96;
				assign vsync_pulse_start = 10;
				assign vsync_pulse_size = 2;
				assign invert = 1;
			end
			2, 3: begin : genblk1
				assign frame_width = 858;
				assign frame_height = 525;
				assign screen_width = 720;
				assign screen_height = 480;
				assign hsync_pulse_start = 16;
				assign hsync_pulse_size = 62;
				assign vsync_pulse_start = 9;
				assign vsync_pulse_size = 6;
				assign invert = 1;
			end
			4: begin : genblk1
				assign frame_width = 1650;
				assign frame_height = 750;
				assign screen_width = 1280;
				assign screen_height = 720;
				assign hsync_pulse_start = 110;
				assign hsync_pulse_size = 40;
				assign vsync_pulse_start = 5;
				assign vsync_pulse_size = 5;
				assign invert = 0;
			end
			16, 34: begin : genblk1
				assign frame_width = 2200;
				assign frame_height = 1125;
				assign screen_width = 1920;
				assign screen_height = 1080;
				assign hsync_pulse_start = 88;
				assign hsync_pulse_size = 44;
				assign vsync_pulse_start = 4;
				assign vsync_pulse_size = 5;
				assign invert = 0;
			end
			17, 18: begin : genblk1
				assign frame_width = 864;
				assign frame_height = 625;
				assign screen_width = 720;
				assign screen_height = 576;
				assign hsync_pulse_start = 12;
				assign hsync_pulse_size = 64;
				assign vsync_pulse_start = 5;
				assign vsync_pulse_size = 5;
				assign invert = 1;
			end
			19: begin : genblk1
				assign frame_width = 1980;
				assign frame_height = 750;
				assign screen_width = 1280;
				assign screen_height = 720;
				assign hsync_pulse_start = 440;
				assign hsync_pulse_size = 40;
				assign vsync_pulse_start = 5;
				assign vsync_pulse_size = 5;
				assign invert = 0;
			end
			95, 105, 97, 107: begin : genblk1
				assign frame_width = 4400;
				assign frame_height = 2250;
				assign screen_width = 3840;
				assign screen_height = 2160;
				assign hsync_pulse_start = 176;
				assign hsync_pulse_size = 88;
				assign vsync_pulse_start = 8;
				assign vsync_pulse_size = 10;
				assign invert = 0;
			end
		endcase
	endgenerate
	always @(*) begin
		if (_sv2v_0)
			;
		hsync <= invert ^ ((cx >= (screen_width + hsync_pulse_start)) && (cx < ((screen_width + hsync_pulse_start) + hsync_pulse_size)));
		if (cy == (screen_height + vsync_pulse_start))
			vsync <= invert ^ (cx >= (screen_width + hsync_pulse_start));
		else if (cy == ((screen_height + vsync_pulse_start) + vsync_pulse_size))
			vsync <= invert ^ (cx < (screen_width + hsync_pulse_start));
		else
			vsync <= invert ^ ((cy >= (screen_height + vsync_pulse_start)) && (cy < ((screen_height + vsync_pulse_start) + vsync_pulse_size)));
	end
	localparam real VIDEO_RATE = (VIDEO_ID_CODE == 1 ? 25.2E6 : ((VIDEO_ID_CODE == 2) || (VIDEO_ID_CODE == 3) ? 27.027E6 : (VIDEO_ID_CODE == 4 ? 74.25E6 : (VIDEO_ID_CODE == 16 ? 148.5E6 : ((VIDEO_ID_CODE == 17) || (VIDEO_ID_CODE == 18) ? 27E6 : (VIDEO_ID_CODE == 19 ? 74.25E6 : (VIDEO_ID_CODE == 34 ? 74.25E6 : ((((VIDEO_ID_CODE == 95) || (VIDEO_ID_CODE == 105)) || (VIDEO_ID_CODE == 97)) || (VIDEO_ID_CODE == 107) ? 594E6 : 0)))))))) * ((VIDEO_REFRESH_RATE == 59.94) || (VIDEO_REFRESH_RATE == 29.97) ? 1000.0 / 1001.0 : 1);
	function automatic signed [BIT_WIDTH - 1:0] sv2v_cast_AA29A_signed;
		input reg signed [BIT_WIDTH - 1:0] inp;
		sv2v_cast_AA29A_signed = inp;
	endfunction
	function automatic signed [BIT_HEIGHT - 1:0] sv2v_cast_FE860_signed;
		input reg signed [BIT_HEIGHT - 1:0] inp;
		sv2v_cast_FE860_signed = inp;
	endfunction
	always @(posedge clk_pixel)
		if (reset) begin
			cx <= sv2v_cast_AA29A_signed(START_X);
			cy <= sv2v_cast_FE860_signed(START_Y);
		end
		else begin
			cx <= (cx == (frame_width - 1'b1) ? sv2v_cast_AA29A_signed(0) : cx + 1'b1);
			cy <= (cx == (frame_width - 1'b1) ? (cy == (frame_height - 1'b1) ? sv2v_cast_FE860_signed(0) : cy + 1'b1) : cy);
		end
	reg video_data_period = 0;
	always @(posedge clk_pixel)
		if (reset)
			video_data_period <= 0;
		else
			video_data_period <= (cx < screen_width) && (cy < screen_height);
	reg [2:0] mode = 3'd1;
	reg [23:0] video_data = 24'd0;
	reg [5:0] control_data = 6'd0;
	reg [11:0] data_island_data = 12'd0;
	function automatic signed [4:0] sv2v_cast_5_signed;
		input reg signed [4:0] inp;
		sv2v_cast_5_signed = inp;
	endfunction
	function automatic [4:0] sv2v_cast_5;
		input reg [4:0] inp;
		sv2v_cast_5 = inp;
	endfunction
	generate
		if (!DVI_OUTPUT) begin : true_hdmi_output
			reg video_guard = 1;
			reg video_preamble = 0;
			always @(posedge clk_pixel)
				if (reset) begin
					video_guard <= 1;
					video_preamble <= 0;
				end
				else begin
					video_guard <= ((cx >= (frame_width - 2)) && (cx < frame_width)) && ((cy == (frame_height - 1)) || (cy < screen_height));
					video_preamble <= ((cx >= (frame_width - 10)) && (cx < (frame_width - 2))) && ((cy == (frame_height - 1)) || (cy < screen_height));
				end
			reg signed [31:0] max_num_packets_alongside;
			reg [4:0] num_packets_alongside;
			always @(*) begin
				if (_sv2v_0)
					;
				max_num_packets_alongside = ((frame_width - screen_width) - 34) / 32;
				if (max_num_packets_alongside > 18)
					num_packets_alongside = 5'd18;
				else
					num_packets_alongside = sv2v_cast_5_signed(max_num_packets_alongside);
			end
			wire data_island_period_instantaneous;
			assign data_island_period_instantaneous = ((num_packets_alongside > 0) && (cx >= (screen_width + 10))) && (cx < ((screen_width + 10) + (num_packets_alongside * 32)));
			wire packet_enable;
			assign packet_enable = data_island_period_instantaneous && (sv2v_cast_5((cx + screen_width) + 22) == 5'd0);
			reg data_island_guard = 0;
			reg data_island_preamble = 0;
			reg data_island_period = 0;
			always @(posedge clk_pixel)
				if (reset) begin
					data_island_guard <= 0;
					data_island_preamble <= 0;
					data_island_period <= 0;
				end
				else begin
					data_island_guard <= (num_packets_alongside > 0) && (((cx >= (screen_width + 8)) && (cx < (screen_width + 10))) || ((cx >= ((screen_width + 10) + (num_packets_alongside * 32))) && (cx < (((screen_width + 10) + (num_packets_alongside * 32)) + 2))));
					data_island_preamble <= ((num_packets_alongside > 0) && (cx >= screen_width)) && (cx < (screen_width + 8));
					data_island_period <= data_island_period_instantaneous;
				end
			wire [23:0] header;
			wire [223:0] sub;
			wire video_field_end;
			assign video_field_end = (cx == (screen_width - 1'b1)) && (cy == (screen_height - 1'b1));
			wire [4:0] packet_pixel_counter;
			packet_picker #(
				.VIDEO_ID_CODE(VIDEO_ID_CODE),
				.VIDEO_RATE(VIDEO_RATE),
				.IT_CONTENT(IT_CONTENT),
				.AUDIO_RATE(AUDIO_RATE),
				.AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
				.VENDOR_NAME(VENDOR_NAME),
				.PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION),
				.SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION)
			) packet_picker(
				.clk_pixel(clk_pixel),
				.clk_audio(clk_audio),
				.reset(reset),
				.video_field_end(video_field_end),
				.packet_enable(packet_enable),
				.packet_pixel_counter(packet_pixel_counter),
				.audio_sample_word(audio_sample_word),
				.header(header),
				.sub(sub)
			);
			wire [8:0] packet_data;
			packet_assembler packet_assembler(
				.clk_pixel(clk_pixel),
				.reset(reset),
				.data_island_period(data_island_period),
				.header(header),
				.sub(sub),
				.packet_data(packet_data),
				.counter(packet_pixel_counter)
			);
			always @(posedge clk_pixel)
				if (reset) begin
					mode <= 3'd2;
					video_data <= 24'd0;
					control_data = 6'd0;
					data_island_data <= 12'd0;
				end
				else begin
					mode <= (data_island_guard ? 3'd4 : (data_island_period ? 3'd3 : (video_guard ? 3'd2 : (video_data_period ? 3'd1 : 3'd0))));
					video_data <= rgb;
					control_data <= {1'b0, data_island_preamble, 1'b0, video_preamble || data_island_preamble, vsync, hsync};
					data_island_data[11:4] <= packet_data[8:1];
					data_island_data[3] <= cx != 0;
					data_island_data[2] <= packet_data[0];
					data_island_data[1:0] <= {vsync, hsync};
				end
		end
		else begin : genblk2
			always @(posedge clk_pixel)
				if (reset) begin
					mode <= 3'd0;
					video_data <= 24'd0;
					control_data <= 6'd0;
				end
				else begin
					mode <= (video_data_period ? 3'd1 : 3'd0);
					video_data <= rgb;
					control_data <= {4'b0000, vsync, hsync};
				end
		end
	endgenerate
	wire [29:0] tmds_internal;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < NUM_CHANNELS; _gv_i_1 = _gv_i_1 + 1) begin : tmds_gen
			localparam i = _gv_i_1;
			tmds_channel #(.CN(i)) tmds_channel(
				.clk_pixel(clk_pixel),
				.video_data(video_data[(i * 8) + 7:i * 8]),
				.data_island_data(data_island_data[(i * 4) + 3:i * 4]),
				.control_data(control_data[(i * 2) + 1:i * 2]),
				.mode(mode),
				.tmds(tmds_internal[i * 10+:10])
			);
			
			dvi_tx_tmds_phy dvi_tx_tmds_phy_inst(
				
				.pixel_clock		(clk_pixel),
				.ddr_bit_clock		(clk_pixel_x5),
				.reset				(reset),
				.data				(tmds_internal[(10*i) +: 10]),
				.tmds_lane			(tmds[i])
			);
		end
	endgenerate
	
	dvi_tx_tmds_phy clock_phy(
		
		.pixel_clock		(clk_pixel),
		.ddr_bit_clock		(clk_pixel_x5),
		.reset				(reset),
		.data				(10'b0000011111),
		.tmds_lane			(tmds_clock)
	);
	
	initial _sv2v_0 = 0;
endmodule

