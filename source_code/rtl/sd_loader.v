// HXIMAGE3: one checked header sector and 153600 BC1 payload bytes.
module sd_loader #(parameter FB_PIXELS=76800, FB_SECTORS=301)(
 input wire clk,rst_n,sd_init_done,load_req,fb_ready,input wire [31:0] base_sector,
 input wire [7:0] sd_data,input wire sd_valid,sd_read_end,
 output reg sd_read,output reg [31:0] sd_addr,output reg load_ack,fb_we,
 output reg [16:0] fb_addr,output reg [15:0] fb_data,output reg load_done,
 output reg [31:0] expected_crc,output reg format_error
);
 localparam IDLE=0,READ=1,NEXT=2,CHECK=3,DONE=4,BAD=5;
 reg [2:0] state;reg [31:0] sector;reg [8:0] sec_cnt;
 reg [16:0] wr_ptr;reg phase;reg [7:0] low_byte;reg [9:0] received;
 reg [255:0] header;reg [31:0] hcrc;
 function [31:0] crc_byte;
 input [31:0] c;input [7:0] d;reg [31:0] v;integer k;
 begin v=c^d;for(k=0;k<8;k=k+1)v=v[0]?((v>>1)^32'hedb88320):(v>>1);crc_byte=v;end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;sector<=0;sec_cnt<=0;wr_ptr<=0;phase<=0;low_byte<=0;
   sd_read<=0;sd_addr<=0;load_ack<=0;fb_we<=0;fb_addr<=0;fb_data<=0;load_done<=0;
   header<=0;hcrc<=32'hffffffff;expected_crc<=0;format_error<=0;received<=0;
  end else begin
   load_ack<=0;fb_we<=0;
   case(state)
    IDLE: if(load_req&&sd_init_done&&fb_ready) begin
     sector<=base_sector;sd_addr<=base_sector;sd_read<=1;load_ack<=1;
     load_done<=0;wr_ptr<=0;sec_cnt<=0;phase<=0;received<=0;
     header<=0;hcrc<=32'hffffffff;format_error<=0;state<=READ;
    end
    READ: begin
     if(sd_valid) begin
      sd_read<=0;received<=received+1'b1;
      if(received>=512) begin format_error<=1;state<=BAD;end
      else if(sec_cnt==0) begin
       if(received<32) header[received*8+:8]<=sd_data;
       if(received<28) hcrc<=crc_byte(hcrc,sd_data);
      end else if(wr_ptr<FB_PIXELS) begin
       phase<=~phase;
       if(!phase)low_byte<=sd_data;
       else begin fb_we<=1;fb_addr<=wr_ptr;fb_data<={sd_data,low_byte};wr_ptr<=wr_ptr+1'b1;end
      end
     end
     if(sd_read_end) begin
      sd_read<=0;
      if((received+(sd_valid?1:0))!=512) begin format_error<=1;state<=BAD;end
      else state<=(sec_cnt==0)?CHECK:NEXT;
     end
    end
    CHECK: begin
     if(header[63:0]!=64'h334547414d495848 || header[95:64]!=3 ||
        header[127:96]!=640 || header[159:128]!=480 ||
        header[191:160]!=153600 || header[255:224]!=(~hcrc)) begin
      format_error<=1;state<=BAD;
     end else begin expected_crc<=header[223:192];state<=NEXT;end
    end
    NEXT: if(fb_ready) begin
     if(sec_cnt==FB_SECTORS-1) begin
      if(wr_ptr==FB_PIXELS&&!phase)state<=DONE;
      else begin format_error<=1;state<=BAD;end
     end else begin sec_cnt<=sec_cnt+1'b1;sd_addr<=sector+sec_cnt+1'b1;
      received<=0;sd_read<=1;state<=READ;end
    end
    DONE: begin load_done<=1;state<=IDLE;end
    BAD: sd_read<=0;
    default:state<=IDLE;
   endcase
  end
 end
endmodule

// HXVIDEO3 raw-media player. Slot layout is shared with tools/mp4_to_tf_video.py.
// Up to 32 slots of 1048576 sectors start at fixed LBA 8388608 (4 GiB).
// Header-selected 4/6 fps: 300 BC1 sectors plus 47/32 PCM sectors.
// Audio is the 48 kHz master; video is loaded one frame ahead. All requests
// stay asserted through the first CRC-verified byte, including card recovery.
module tf_video_player (
    input wire clk, rst_n, init_done,
    input wire [32:0] card_sectors,
    input wire [4:0] slot,
    input wire sample_tick, swap_ack, fb_ready, frame_stored,
    input wire [7:0] sd_data,
    input wire sd_valid, sd_end,
    output reg sd_read,
    output reg [31:0] sd_addr,
    output reg fb_we,
    output reg [16:0] fb_addr,
    output reg [15:0] fb_data,
    output reg write_bank, swap_request, publish_bank, picture_valid,
    output reg signed [15:0] pcm,
    output reg format_error, underrun,
    input wire loop_enable,
    input wire paused,
    output reg [9:0] seconds_gray,
    output wire stopped
);
    localparam WAIT_CARD=0, READ_BLOCK=1, END_BLOCK=2, CHECK_HEADER=3, SCHEDULE=4, BAD=5, WAIT_STORE=6;
    reg [2:0] state;
    reg [1:0] kind; // 0=video, 1=audio, 2=header
    reg [8:0] byte_index;
    reg [7:0] low_byte;
    reg [447:0] header;
    reg [31:0] header_crc;
    reg [31:0] slot_base;
    // Explicit media cursors: no register retiming into address multipliers.
    // These remain stable for the complete frame, including stalls/retries.
    reg [31:0] video_lba,audio_lba;
    reg [12:0] frames, video_frame, audio_frame;
    reg [8:0] video_sector;
    reg [5:0] audio_sector;
    reg [16:0] pixel_count;
    reg ready, swap_wait, playing;
    reg [13:0] played_samples;
    reg [13:0] samples_per_frame;
    reg [8:0] record_sectors, last_audio_bytes;
    reg [5:0] audio_sectors;
    reg [12:0] played_frame;
    reg ended, rebuffer;
    assign stopped=ended;
    reg audio_wrapped;
    reg [9:0] received_bytes;
    reg [1:0] ack_sync;
    reg [9:0] wp, rp;
    reg [10:0] level;
    reg [15:0] fifo_q;
    (* ram_style="dram" *) reg [15:0] fifo [0:1023];
    wire push = (state==READ_BLOCK)&&(kind==1)&&sd_valid&&(received_bytes<512)&&
                (level<1024)&&byte_index[0]&&
                ((audio_sector!=audio_sectors-1'b1)||(byte_index<last_audio_bytes));
    wire last_once = (played_frame==frames-1'b1)&&!loop_enable;
    wire boundary_blocked = (played_samples==samples_per_frame-1'b1)&&!last_once&&(!ready||swap_wait);
    wire pop = playing&&!ended&&!rebuffer&&!paused&&sample_tick&&(level!=0)&&!boundary_blocked;
    reg [15:0] second_samples;
    reg [9:0] elapsed_seconds;
    wire [9:0] next_seconds=elapsed_seconds+1'b1;
    // Applied only after a real underrun: fade back in without altering normal PCM.
    reg [8:0] recovery_gain;
    wire signed [25:0] recovered_pcm = $signed(fifo_q)*$signed({1'b0,recovery_gain});
    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0] d;
        reg [31:0] v;
        integer k;
        begin
            v=c^{24'd0,d};
            for(k=0;k<8;k=k+1) v=v[0]?((v>>1)^32'hedb88320):(v>>1);
            crc_byte=v;
        end
    endfunction
    // Synchronous RAM output is prefetched for a full sample period after rp changes.
    always @(posedge clk) begin
        if(push) fifo[wp]<={sd_data,low_byte};
        fifo_q<=fifo[rp];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT_CARD;kind<=2;sd_read<=0;sd_addr<=0;byte_index<=0;
            low_byte<=0;header<=0;header_crc<=32'hffffffff;slot_base<=0;
            video_lba<=0;audio_lba<=0;
            frames<=0;video_frame<=0;audio_frame<=0;video_sector<=0;audio_sector<=0;
            pixel_count<=0;fb_we<=0;fb_addr<=0;fb_data<=0;
            write_bank<=1;swap_request<=0;publish_bank<=1;picture_valid<=0;
            ready<=0;swap_wait<=0;playing<=0;played_samples<=0;pcm<=0;
            played_frame<=0;ended<=0;rebuffer<=0;received_bytes<=0;recovery_gain<=256;
            audio_wrapped<=0;
            samples_per_frame<=12000;record_sectors<=347;
            audio_sectors<=47;last_audio_bytes<=448;
            wp<=0;rp<=0;level<=0;ack_sync<=0;format_error<=0;underrun<=0;
            second_samples<=0;elapsed_seconds<=0;seconds_gray<=0;
        end else begin
            ack_sync<={ack_sync[0],swap_ack};
            fb_we<=0;
            if(push) wp<=wp+1'b1;
            if(pop) rp<=rp+1'b1;
            case({push,pop})
                2'b10: level<=level+1'b1;
                2'b01: level<=level-1'b1;
                default: begin end
            endcase
            if(swap_wait&&(ack_sync[1]==swap_request)) begin
                swap_wait<=0;write_bank<=~publish_bank;picture_valid<=1;
            end
            if(picture_valid&&!playing&&!ended&&(level>=768)) playing<=1;
            // At one-shot EOF there may be fewer than 768 samples remaining.
            // Drain the verified tail rather than waiting for nonexistent data.
            if(rebuffer&&((level>=768)||(last_once&&audio_wrapped&&(level!=0)))&&
               !boundary_blocked&&(pcm==0)) begin
                rebuffer<=0;recovery_gain<=0;
            end
            // Publish the initial frame before starting its PCM stream.
            if(ready&&!picture_valid&&!swap_wait&&!paused) begin
                publish_bank<=write_bank;swap_request<=~swap_request;
                swap_wait<=1;ready<=0;video_frame<=(frames==1)?0:1;
                video_lba<=slot_base+32'd1+((frames==1)?32'd0:{23'd0,record_sectors});
            end
            if(sample_tick) begin
                if(paused) begin pcm<=0;recovery_gain<=0;end
                else if(pop) begin
                    if(second_samples==47999) begin
                        second_samples<=0;elapsed_seconds<=next_seconds;
                        seconds_gray<=next_seconds^(next_seconds>>1);
                    end else second_samples<=second_samples+1'b1;
                    pcm<=recovered_pcm>>>8;
                    if(recovery_gain<256) recovery_gain<=recovery_gain+8;
                    if(played_samples==samples_per_frame-1'b1) begin
                        played_samples<=0;
                        if(last_once) begin
                            ended<=1;playing<=0;ready<=0;
                        end else begin
                            if(played_frame==frames-1'b1) begin
                                elapsed_seconds<=0;second_samples<=0;seconds_gray<=0;
                                audio_wrapped<=0;
                            end
                            played_frame<=(played_frame==frames-1'b1)?0:played_frame+1'b1;
                            publish_bank<=write_bank;swap_request<=~swap_request;
                            swap_wait<=1;ready<=0;
                            video_frame<=(video_frame==frames-1'b1)?0:video_frame+1'b1;
                            video_lba<=(video_frame==frames-1'b1)?slot_base+32'd1:video_lba+{23'd0,record_sectors};
                        end
                    end else played_samples<=played_samples+1'b1;
                end else begin
                    // Decay to silence instead of alternating arbitrary samples and zero.
                    if(pcm>16'sd256) pcm<=pcm-16'sd256;
                    else if(pcm< -16'sd256) pcm<=pcm+16'sd256;
                    else pcm<=0;
                    if(playing&&!ended) begin underrun<=1;rebuffer<=1;end
                end
            end
            case(state)
                WAIT_CARD: if(init_done) begin
                    // Require the entire selected 512 MiB slot to fit the reported card.
                    // CSD cannot detect counterfeit capacity; use verified media.
                    if(card_sectors<(33'd9437184+({28'd0,slot}<<20))) begin format_error<=1;state<=BAD;end
                    else begin
                        slot_base<=33'd8388608+({28'd0,slot}<<20);
                        sd_addr<=33'd8388608+({28'd0,slot}<<20);
                        sd_read<=1;kind<=2;byte_index<=0;received_bytes<=0;state<=READ_BLOCK;
                    end
                end
                READ_BLOCK: begin
                    if(sd_valid) begin
                        sd_read<=0;
                        if(received_bytes<513) received_bytes<=received_bytes+1'b1;
                        byte_index<=byte_index+1'b1;
                        if(kind==2) begin
                            if(byte_index<56) header[byte_index*8+:8]<=sd_data;
                            if(byte_index<52) header_crc<=crc_byte(header_crc,sd_data);
                        end else begin
                            if(!byte_index[0]) low_byte<=sd_data;
                            else if((kind==0)&&(pixel_count<76800)&&(received_bytes<512)) begin
                                fb_we<=1;fb_addr<=pixel_count;
                                fb_data<={sd_data,low_byte};pixel_count<=pixel_count+1'b1;
                            end
                        end
                    end
                    if(sd_end) begin
                        sd_read<=0;state<=END_BLOCK;
                        if((received_bytes+(sd_valid?1:0))!=512) begin
                            format_error<=1;state<=BAD;picture_valid<=0;
                        end
                    end
                    if((kind==1)&&sd_valid&&byte_index[0]&&(level==1024)) begin
                        format_error<=1;state<=BAD;sd_read<=0;
                    end
                end
                END_BLOCK: begin
                    if(kind==2) state<=CHECK_HEADER;
                    else begin
                        state<=SCHEDULE;
                        if(kind==0) begin
                            if(video_sector==299) begin
                                video_sector<=0;pixel_count<=0;
                                if(pixel_count==76800) state<=WAIT_STORE;
                                else begin format_error<=1;state<=BAD;end
                            end
                            else video_sector<=video_sector+1'b1;
                        end else begin
                            if(audio_sector==audio_sectors-1'b1) begin
                                audio_sector<=0;
                                audio_frame<=(audio_frame==frames-1'b1)?0:audio_frame+1'b1;
                                audio_lba<=(audio_frame==frames-1'b1)?slot_base+32'd301:audio_lba+{23'd0,record_sectors};
                                if(audio_frame==frames-1'b1) audio_wrapped<=1;
                            end else audio_sector<=audio_sector+1'b1;
                        end
                    end
                end
                CHECK_HEADER: begin
                    if((header[63:0]!=64'h334f454449565848)||
                       (header[95:64]!=3)||(header[127:96]!=640)||
                       (header[159:128]!=480)||(header[223:192]!=48000)||
                       (header[287:256]==0)||(header[351:320]!=300)||
                       !(((header[191:160]==4)&&(header[255:224]==12000)&&
                          (header[319:288]==347)&&(header[383:352]==47)&&(header[287:256]<=3021))||
                         ((header[191:160]==6)&&(header[255:224]==8000)&&
                          (header[319:288]==332)&&(header[383:352]==32)&&(header[287:256]<=3158)))||
                       (header[415:384]!={27'd0,slot})||
                       (header[447:416]!=(~header_crc))) begin
                        format_error<=1;state<=BAD;
                    end else begin
                        frames<=header[268:256];state<=SCHEDULE;
                        samples_per_frame<=header[237:224];
                        record_sectors<=header[296:288];audio_sectors<=header[357:352];
                        last_audio_bytes<=(header[191:160]==6)?9'd128:9'd448;
                        video_lba<=slot_base+32'd1;audio_lba<=slot_base+32'd301;
                    end
                end
                SCHEDULE: begin
                    // Reserve at least one whole sector of FIFO space before CMD17.
                    // Audio reads can continue during the vertical-blank swap handshake.
                    if(!ended&&picture_valid&&(level<=768)&&(loop_enable||!audio_wrapped)) begin
                        kind<=1;byte_index<=0;received_bytes<=0;sd_read<=1;state<=READ_BLOCK;
                        sd_addr<=audio_lba+{26'd0,audio_sector};
                    end else if(!ended&&!ready&&!swap_wait&&fb_ready&&
                        !(picture_valid&&!loop_enable&&(played_frame==frames-1'b1))) begin
                        kind<=0;byte_index<=0;received_bytes<=0;sd_read<=1;state<=READ_BLOCK;
                        sd_addr<=video_lba+{23'd0,video_sector};
                    end
                end
                WAIT_STORE: if(frame_stored)begin ready<=1;state<=SCHEDULE;end
                BAD: begin sd_read<=0;pcm<=0;end
                default: state<=WAIT_CARD;
            endcase
        end
    end
endmodule
