// Verified, read-only SDHC/SDXC SPI reader for the TF picture application.
// A full sector is buffered and checked before any bytes reach sd_loader.
// The unused legacy write ports stay present for top-level compatibility.
module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV = 248,
    parameter SPI_HIGH_SPEED_DIV = 23
)(
    input clk, rst,
    input video_speed,
    output reg [32:0] card_sectors,
    output SD_nCS, SD_DCLK, SD_MOSI,
    input SD_MISO,
    output reg sd_init_done,
    input sd_sec_read,
    input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid,
    output reg sd_sec_read_end,
    input sd_sec_write,
    input [31:0] sd_sec_write_addr,
    input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req, sd_sec_write_end,
    output reg sd_read_error
);
    assign sd_sec_write_data_req = 1'b0;
    assign sd_sec_write_end = 1'b0;
    localparam S_BOOT=0, S_CLOCKS=1, S_SELECT=2, S_TX=3, S_R1=4,
               S_EXT=5, S_POST=6, S_IDLE=7, S_TOKEN=8, S_DATA=9,
               S_CRC_H=10, S_CRC_L=11, S_CHECK=12, S_EMIT=13, S_END=14,
               S_CSD_TOKEN=15, S_CSD_DATA=16, S_CSD_H=17, S_CSD_L=18,
               S_CSD_CHECK=19,S_VERIFY_READ=20,S_VERIFY_DRAIN=21,S_VERIFY_CHECK=22;
    localparam P_NEXT=0, P_IDLE=1, P_EMIT=2, P_RETRY=3;
    reg [4:0] state;
    reg [127:0] csd;
    reg [3:0] csd_index;
    reg [1:0] post_action;
    reg cs;
    reg [5:0] command_id;
    reg [31:0] command_arg, sector_addr;
    reg [2:0] command_index;
    reg [6:0] command_crc;
    reg [3:0] clock_bytes;
    reg [15:0] poll_count;
    reg [9:0] init_tries;
    reg [1:0] ext_count, retry_count;
    reg [31:0] ext_value;
    reg [8:0] data_index, emit_index;
    reg [15:0] data_crc, received_crc;
    reg [15:0] cache_crc;
    reg cache_valid;

    function [6:0] crc7_byte;
        input [6:0] old_crc;
        input [7:0] value;
        reg [6:0] c;
        integer i;
        begin
            c=old_crc;
            for(i=7;i>=0;i=i-1)
                c=(c[6]^value[i]) ? ((c<<1)^7'h09) : (c<<1);
            crc7_byte=c;
        end
    endfunction
    function [15:0] crc16_byte;
        input [15:0] old_crc;
        input [7:0] value;
        reg [15:0] c;
        integer i;
        begin
            c=old_crc ^ {value,8'd0};
            for(i=0;i<8;i=i+1)
                c=c[15] ? ((c<<1)^16'h1021) : (c<<1);
            crc16_byte=c;
        end
    endfunction

    // Explicit one-request/one-acknowledgement byte transport.
    // Picture mode retains its verified 1 MHz divider. Video is separately tested.
    // A failed video transfer falls back from 12.5 to 8.33 MHz for this session.
    // Change only between transactions, never in the middle of an SPI byte.
    reg video_slow;
    wire [15:0] spi_div = sd_init_done ? (video_speed ? (video_slow?16'd1:16'd0) : SPI_HIGH_SPEED_DIV) : SPI_LOW_SPEED_DIV;
    wire spi_ack;
    wire [7:0] spi_rx;
    reg spi_req, spi_pending;
    reg [7:0] spi_tx;
    reg byte_wanted;
    reg [7:0] byte_value;
    wire byte_done = spi_pending && spi_ack;
    always @(*) begin
        byte_wanted=1'b0;
        byte_value=8'hff;
        case(state)
            S_CLOCKS,S_SELECT,S_R1,S_EXT,S_POST,S_TOKEN,S_DATA,S_CRC_H,S_CRC_L,
            S_CSD_TOKEN,S_CSD_DATA,S_CSD_H,S_CSD_L:
                byte_wanted=1'b1;
            S_TX: begin
                byte_wanted=1'b1;
                case(command_index)
                    0: byte_value={2'b01,command_id};
                    1: byte_value=command_arg[31:24];
                    2: byte_value=command_arg[23:16];
                    3: byte_value=command_arg[15:8];
                    4: byte_value=command_arg[7:0];
                    default: byte_value={command_crc,1'b1};
                endcase
            end
            default: begin end
        endcase
    end
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            spi_req<=1'b0;
            spi_pending<=1'b0;
            spi_tx<=8'hff;
        end else if(byte_done) begin
            spi_req<=1'b0;
            spi_pending<=1'b0;
        end else if(!spi_pending && !spi_ack && byte_wanted) begin
            spi_tx<=byte_value;
            spi_req<=1'b1;
            spi_pending<=1'b1;
        end
    end
    spi_master transport(
        .sys_clk(clk),.rst(rst),.nCS(SD_nCS),.DCLK(SD_DCLK),
        .MOSI(SD_MOSI),.MISO(SD_MISO),.CPOL(1'b1),.CPHA(1'b1),
        .nCS_ctrl(cs),.clk_div(spi_div),.wr_req(spi_req),
        .wr_ack(spi_ack),.data_in(spi_tx),.data_out(spi_rx)
    );

    // Canonical single-write/synchronous-read RAM, with no array reset.
    (* ram_style="dram" *) reg [7:0] sector_buffer [0:511];
    always @(posedge clk) begin
        if((state==S_DATA) && byte_done)
            sector_buffer[data_index]<=spi_rx;
    end
    always @(posedge clk) begin
        if((state==S_EMIT)||(state==S_VERIFY_READ)) sd_sec_read_data<=sector_buffer[emit_index];
    end

    task queue_command;
        input [5:0] id;
        input [31:0] arg;
        begin
            command_id<=id;
            command_arg<=arg;
            cs<=1'b1;
            post_action<=P_NEXT;
            state<=S_POST;
        end
    endtask
    task read_retry;
        begin
            sd_read_error<=1'b1;
            if(video_speed) video_slow<=1'b1;
            cs<=1'b1;
            if(retry_count==2'd3) begin
                sd_init_done<=1'b0;
                state<=S_BOOT;
            end else begin
                retry_count<=retry_count+1'b1;
                post_action<=P_RETRY;
                state<=S_POST;
            end
        end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=S_BOOT;
            post_action<=P_NEXT;
            cs<=1'b1;
            sd_init_done<=1'b0;
            card_sectors<=0;csd<=0;csd_index<=0;
            sd_read_error<=1'b0;
            video_slow<=1'b0;
            sd_sec_read_data_valid<=1'b0;
            sd_sec_read_end<=1'b0;
            command_id<=0;command_arg<=0;sector_addr<=0;
            command_index<=0;command_crc<=0;clock_bytes<=0;
            poll_count<=0;init_tries<=0;ext_count<=0;ext_value<=0;
            retry_count<=0;data_index<=0;emit_index<=0;
            data_crc<=0;received_crc<=0;
            cache_crc<=0;cache_valid<=0;
        end else begin
            sd_sec_read_data_valid<=1'b0;
            sd_sec_read_end<=1'b0;
            case(state)
                S_BOOT: begin
                    cs<=1'b1;
                    sd_init_done<=1'b0;
                    clock_bytes<=0;init_tries<=0;retry_count<=0;
                    state<=S_CLOCKS;
                end
                S_CLOCKS: if(byte_done) begin
                    if(clock_bytes==4'd9) queue_command(6'd0,32'd0);
                    else clock_bytes<=clock_bytes+1'b1;
                end
                S_POST: if(byte_done) begin
                    case(post_action)
                        P_NEXT: begin
                            command_index<=0;command_crc<=0;poll_count<=0;
                            state<=S_SELECT;
                        end
                        P_IDLE: state<=S_IDLE;
                        P_EMIT: begin
                            emit_index<=0;cache_crc<=0;cache_valid<=0;
                            state<=S_VERIFY_READ;
                        end
                        default: begin
                            command_id<=6'd17;command_arg<=sector_addr;
                            command_index<=0;command_crc<=0;poll_count<=0;
                            state<=S_SELECT;
                        end
                    endcase
                end
                S_SELECT: begin
                    cs<=1'b0;
                    if(byte_done) state<=S_TX;
                end
                S_TX: if(byte_done) begin
                    if(command_index<5) command_crc<=crc7_byte(command_crc,spi_tx);
                    if(command_index==5) begin state<=S_R1;poll_count<=0;end
                    else command_index<=command_index+1'b1;
                end
                // Only bytes AFTER the six-byte command can be an R1.
                S_R1: if(byte_done) begin
                    if(!spi_rx[7]) begin
                        case(command_id)
                            0: if(spi_rx==1) queue_command(6'd8,32'h000001aa);
                               else state<=S_BOOT;
                            8: if(spi_rx==1) begin
                                   ext_count<=0;ext_value<=0;state<=S_EXT;
                               end else state<=S_BOOT;
                            55: if((spi_rx==1)||(spi_rx==0))
                                    queue_command(6'd41,32'h40000000);
                                else state<=S_BOOT;
                            41: if(spi_rx==0) queue_command(6'd58,32'd0);
                                else if((spi_rx==1)&&(init_tries!=10'h3ff)) begin
                                    init_tries<=init_tries+1'b1;
                                    queue_command(6'd55,32'd0);
                                end else state<=S_BOOT;
                            58: if(spi_rx==0) begin
                                    ext_count<=0;ext_value<=0;state<=S_EXT;
                                end else state<=S_BOOT;
                            59: if(spi_rx==0) begin
                                    if(video_speed) queue_command(6'd9,32'd0);
                                    else begin
                                        sd_init_done<=1'b1;cs<=1'b1;
                                        post_action<=P_IDLE;state<=S_POST;
                                    end
                                end else state<=S_BOOT;
                            9: if(spi_rx==0) begin poll_count<=0;state<=S_CSD_TOKEN;end
                               else state<=S_BOOT;
                            17: if(spi_rx==0) begin poll_count<=0;state<=S_TOKEN;end
                                else read_retry();
                            default: state<=S_BOOT;
                        endcase
                    end else if(poll_count==16'd63) begin
                        if(command_id==17) read_retry();
                        else state<=S_BOOT;
                    end else poll_count<=poll_count+1'b1;
                end
                S_EXT: if(byte_done) begin
                    ext_value<={ext_value[23:0],spi_rx};
                    if(ext_count==3) begin
                        if(command_id==8) begin
                            if({ext_value[23:0],spi_rx}==32'h000001aa)
                                queue_command(6'd55,32'd0);
                            else state<=S_BOOT;
                        end else begin
                            // OCR power-up and CCS bits must both be set.
                            if(ext_value[23:22]==2'b11)
                                queue_command(6'd59,32'd1);
                            else state<=S_BOOT;
                        end
                    end else ext_count<=ext_count+1'b1;
                end
                S_IDLE: if(sd_sec_read) begin
                    sector_addr<=sd_sec_read_addr;
                    retry_count<=0;
                    queue_command(6'd17,sd_sec_read_addr);
                end
                S_CSD_TOKEN: if(byte_done) begin
                    if(spi_rx==8'hfe) begin csd_index<=0;data_crc<=0;csd<=0;state<=S_CSD_DATA;end
                    else if((spi_rx!=8'hff)||(poll_count==16'hffff)) state<=S_BOOT;
                    else poll_count<=poll_count+1'b1;
                end
                S_CSD_DATA: if(byte_done) begin
                    csd<={csd[119:0],spi_rx};data_crc<=crc16_byte(data_crc,spi_rx);
                    if(csd_index==15) state<=S_CSD_H;
                    else csd_index<=csd_index+1'b1;
                end
                S_CSD_H: if(byte_done) begin received_crc[15:8]<=spi_rx;state<=S_CSD_L;end
                S_CSD_L: if(byte_done) begin received_crc[7:0]<=spi_rx;state<=S_CSD_CHECK;end
                S_CSD_CHECK: begin
                    if((data_crc==received_crc)&&(csd[127:126]==2'b01)) begin
                        card_sectors<=({11'd0,csd[69:48]}+33'd1)<<10;
                        sd_init_done<=1'b1;cs<=1'b1;post_action<=P_IDLE;state<=S_POST;
                    end else state<=S_BOOT;
                end
                S_TOKEN: if(byte_done) begin
                    if(spi_rx==8'hfe) begin
                        data_index<=0;data_crc<=0;state<=S_DATA;
                    end else if((spi_rx!=8'hff)||(poll_count==16'hffff)) read_retry();
                    else poll_count<=poll_count+1'b1;
                end
                S_DATA: if(byte_done) begin
                    data_crc<=crc16_byte(data_crc,spi_rx);
                    if(data_index==9'd511) state<=S_CRC_H;
                    else data_index<=data_index+1'b1;
                end
                S_CRC_H: if(byte_done) begin received_crc[15:8]<=spi_rx;state<=S_CRC_L;end
                S_CRC_L: if(byte_done) begin received_crc[7:0]<=spi_rx;state<=S_CHECK;end
                S_CHECK: begin
                    if(data_crc==received_crc) begin
                        sd_read_error<=1'b0;cs<=1'b1;
                        post_action<=P_EMIT;state<=S_POST;
                    end else read_retry();
                end
                // SPI CRC covers received bytes, not a later BRAM read failure.
                // Check the stored sector as well before asserting any valid.
                S_VERIFY_READ: begin
                    cache_valid<=1;
                    if(cache_valid) cache_crc<=crc16_byte(cache_crc,sd_sec_read_data);
                    if(emit_index==511) state<=S_VERIFY_DRAIN;
                    else emit_index<=emit_index+1'b1;
                end
                S_VERIFY_DRAIN: begin
                    cache_crc<=crc16_byte(cache_crc,sd_sec_read_data);
                    cache_valid<=0;state<=S_VERIFY_CHECK;
                end
                S_VERIFY_CHECK: begin
                    if(cache_crc==received_crc) begin emit_index<=0;state<=S_EMIT;end
                    else read_retry();
                end
                S_EMIT: begin
                    sd_sec_read_data_valid<=1'b1;
                    if(emit_index==9'd511) state<=S_END;
                    else emit_index<=emit_index+1'b1;
                end
                S_END: begin
                    sd_sec_read_end<=1'b1;
                    state<=S_IDLE;
                end
                default: state<=S_BOOT;
            endcase
        end
    end
endmodule
