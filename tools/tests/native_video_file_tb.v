`timescale 1ns/1ps
// Actual HXVIDEO3 files, compressed bus/audio timing, independent full-frame
// video and PCM checksums. Long enough to cross 7 s and real clip loop points.
module native_video_file_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=0,tick=0,ack=0,valid=0,done=0,loop_en=1;
    reg [7:0] data=0;
    wire req,we,wb,sw,pb,pv,err,under;
    wire [31:0] addr;
    wire [16:0] wa;
    wire [15:0] wd;
    wire signed [15:0] pcm;
    wire [9:0] seconds;
    reg [4:0] slot=0;
    reg frame_stored=0;
    integer store_wait=0;
    integer timing_model=0,tick_period=40,sector_latency=230,store_latency=70;
    tf_video_player dut(.clk(clk),.rst_n(rst),.init_done(1'b1),.card_sectors(33'd67108864),
        .slot(slot),.sample_tick(tick),.swap_ack(ack),.fb_ready(1'b1),.frame_stored(frame_stored),
        .sd_data(data),.sd_valid(valid),.sd_end(done),.sd_read(req),.sd_addr(addr),
        .fb_we(we),.fb_addr(wa),.fb_data(wd),.write_bank(wb),.swap_request(sw),.publish_bank(pb),
        .picture_valid(pv),.pcm(pcm),.format_error(err),.underrun(under),
        .loop_enable(loop_en),.paused(1'b0),.seconds_gray(seconds));
    always @(posedge clk)begin
        if(we&&wa==0)frame_stored<=0;
        if(we&&wa==76799)store_wait<=store_latency;
        if(store_wait!=0)begin
            store_wait<=store_wait-1;
            if(store_wait==1)frame_stored<=1;
        end
        if(dut.ready&&!frame_stored)$fatal(1,"Frame ready before SDRAM CRC completion");
    end
    reg [7:0] block [0:511];
    reg [31:0] video_crc [0:6897],audio_crc [0:6897];
    reg [31:0] vc=32'hffffffff,ac=32'hffffffff;
    reg [4095:0] media_path,vcrc_path,acrc_path;
    integer fd,n,i,frames=0,target=0,slow=0,once=0,slot_arg=0;
    integer frame_samples=12000,record_sectors=347,audio_sectors=47;
    integer tail_delay=0;
    integer cycles=0,ticks=0,ack_wait=0,samples=0,pixels=0,video_count=0,audio_count=0;
    integer vf=0,vs=0,af=0,asec=0,delay_cycles=0,reads=0,undercount=0;
    reg [31:0] base,address;
    function [31:0] word_crc;
        input [31:0] old;
        input [15:0] value;
        reg [31:0] c;
        integer b,j;
        begin
            c=old;
            for(b=0;b<2;b=b+1) begin
                c=c^((value>>(b*8))&255);
                for(j=0;j<8;j=j+1) c=c[0]?((c>>1)^32'hedb88320):(c>>1);
            end
            word_crc=c;
        end
    endfunction
    always @(negedge clk) begin
        ticks=ticks+1;tick=(ticks%tick_period==0);
        if(rst&&sw!=ack) begin
            ack_wait=ack_wait+1;
            if(ack_wait==600) begin ack=sw;ack_wait=0;end
        end else ack_wait=0;
    end
    always @(posedge clk) if(rst) begin
        cycles=cycles+1;
        if(err) $fatal(1,"Real media format error frame=%0d audio=%0d samples=%0d",video_count,audio_count,samples);
        if(we) begin
            if(wa!==pixels%76800) $fatal(1,"Real media write address mismatch");
            vc=word_crc(vc,wd);pixels=pixels+1;
            if(pixels%76800==0) begin
                if((~vc)!==video_crc[video_count%frames])
                    $fatal(1,"VIDEO CRC mismatch frame=%0d expected=%h got=%h",video_count,video_crc[video_count%frames],~vc);
                video_count=video_count+1;vc=32'hffffffff;
            end
        end
        if(dut.pop) begin
            ac=word_crc(ac,dut.fifo_q);samples=samples+1;
            if(samples%frame_samples==0) begin
                if((~ac)!==audio_crc[audio_count%frames])
                    $fatal(1,"AUDIO CRC mismatch frame=%0d expected=%h got=%h",audio_count,audio_crc[audio_count%frames],~ac);
                audio_count=audio_count+1;ac=32'hffffffff;
                if(audio_count==56||audio_count==frames||audio_count==frames+1)
                    $display("CHECK real file audio_frames=%0d video_frames=%0d cycles=%0d under=%b",audio_count,video_count,cycles,under);
            end
            if(samples==target*frame_samples) begin
                #1;
                if(once) begin
                    if(!dut.ended) $fatal(1,"Real clip did not stop at exact sample count");
                    repeat(5000) @(negedge clk);
                    if(req||pcm!==0||!pv) $fatal(1,"Real clip end did not hold last frame and silence");
                end
                $display("PASS actual media frames=%0d audio_frames=%0d video_frames=%0d samples=%0d reads=%0d slow=%0d once=%0d under=%b",frames,audio_count,video_count,samples,reads,slow,once,under);
                $finish;
            end
        end
    end
    initial begin
        if(!$value$plusargs("MEDIA=%s",media_path)||!$value$plusargs("VCRC=%s",vcrc_path)||
           !$value$plusargs("ACRC=%s",acrc_path)||!$value$plusargs("FRAMES=%d",frames)||
           !$value$plusargs("TARGET=%d",target)) $fatal(1,"Missing real-media arguments");
        if($value$plusargs("SLOT=%d",slot_arg)) begin end
        if($value$plusargs("SLOW=%d",slow)) begin end
        if($value$plusargs("ONCE=%d",once)) begin end
        if($value$plusargs("SAMPLES=%d",frame_samples)) begin end
        if($value$plusargs("RECORD=%d",record_sectors)) begin end
        if($value$plusargs("AUDIO_SECTORS=%d",audio_sectors)) begin end
        if($value$plusargs("REALTIME=%d",timing_model)) begin end
        if($value$plusargs("TAIL_DELAY=%d",tail_delay)) begin end
        if(timing_model) begin
            tick_period=1041;sector_latency=19415;store_latency=300000;
        end
        slot=slot_arg;loop_en=!once;base=8388608+slot_arg*1048576;
        $readmemh(vcrc_path,video_crc,0,frames-1);$readmemh(acrc_path,audio_crc,0,frames-1);
        fd=$fopen(media_path,"rb");if(!fd) $fatal(1,"Cannot open actual video file");
        repeat(6) @(negedge clk);rst=1;
        forever begin
            wait(req);address=addr;reads=reads+1;
            if(dut.kind==0) begin
                if(address!==(base+1+vf*record_sectors+vs)) $fatal(1,"Video LBA sequence failed vf=%0d sector=%0d got=%0d",vf,vs,address);
                vs=vs+1;if(vs==300) begin vs=0;vf=(vf+1)%frames;end
            end else if(dut.kind==1) begin
                if(address!==(base+1+af*record_sectors+300+asec)) $fatal(1,"Audio LBA sequence failed af=%0d sector=%0d got=%0d",af,asec,address);
                asec=asec+1;if(asec==audio_sectors) begin asec=0;af=(af+1)%frames;end
            end else if(address!==base) $fatal(1,"Header LBA mismatch");
            n=$fseek(fd,(address-base)*512,0);n=$fread(block,fd);
            if(n!=512) $fatal(1,"Read beyond actual file: LBA %0d read=%0d",address,n);
            delay_cycles=sector_latency;
            if(slow&&reads%137==0) delay_cycles=sector_latency+5000;
            // af/asec already advanced: zero/zero marks the clip's last sector.
            if(once&&dut.kind==1&&af==0&&asec==0&&tail_delay>delay_cycles)
                delay_cycles=tail_delay;
            repeat(delay_cycles) @(negedge clk);
            for(i=0;i<512;i=i+1) begin @(negedge clk);valid=1;data=block[i];end
            @(negedge clk);valid=0;done=1;
            @(negedge clk);done=0;
        end
    end
    initial begin #200000000000;$fatal(1,"Actual media timeout samples=%0d target=%0d",samples,target*frame_samples);end
endmodule
