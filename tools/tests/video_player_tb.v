`timescale 1ns/1ps
module video_player_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst_n=0,init_done=0,sample_tick=0,manual_ack=0,loop_enable=1;
    wire swap_ack;
    reg [32:0] capacity=33'd67108864;
    reg [4:0] slot=0;
    reg [7:0] data=0;
    reg valid=0,done=0;
    wire req,we,wb,sw,pb,pv,err,under;
    wire [31:0] addr;
    wire [14:0] wa;
    wire [15:0] wd;
    wire signed [15:0] pcm;
    reg paused=0;
    wire [9:0] seconds_gray;
    tf_video_player dut(clk,rst_n,init_done,capacity,slot,sample_tick,swap_ack,
                        data,valid,done,req,addr,we,wa,wd,wb,sw,pb,pv,pcm,err,under,loop_enable,paused,seconds_gray);
    reg [7:0] bytes [0:156159];
    integer slot_arg=0,bad_arg=0;
    integer pause_arg=0,saved_count=0,saved_samples=0,saved_rp=0;
    integer once_arg=0,stall_arg=0,replay_arg=0,dynamic_arg=0;
    integer single_arg=0;
    integer present_arg=0,front_pixel=0,front_frame=0,front_count=0;
    integer refresh=0;
    wire present_ack,present_we,present_busy,present_error;
    wire [12:0] present_ra;
    wire [14:0] present_wa;
    wire [15:0] present_wd,back0,back1,back2,back3;
    wire model_clk=clk&&(present_arg!=0);
    assign swap_ack=present_arg?present_ack:manual_ack;
    framebuffer #(.USE_32K(1),.AUX_READ(1)) back_ram(model_clk,we&&(present_arg!=0),wa,wd,model_clk,
        13'd0,13'd0,13'd0,13'd0,,,,,present_ra,back0,back1,back2,back3);
    video_frame_presenter presenter(model_clk,rst_n&&(present_arg!=0),(refresh>=12000),sw,
        present_ack,present_ra,back0,back1,back2,back3,present_we,present_wa,present_wd,
        present_busy,present_error,we&&(present_arg!=0),present_arg?wa:15'd0,present_arg?wd:16'd0);
    integer injected=0,replayed=0;
    reg stop_swap;
    reg signed [15:0] signed_expected;
    reg signed [25:0] scaled_expected;
    reg [31:0] base;
    integer cnt=0,vcnt=0,a_count=0,expected_frame=0,expected_pixel=0;
    integer playing_bank=0,ticks=0;
    reg [15:0] expected_pcm;
    always @(negedge clk) begin
        sample_tick=(ticks==103);
        ticks=sample_tick?0:ticks+1;
        if(rst_n) begin
            refresh=refresh+1;
            if(refresh==84000) begin
                refresh=0;
                if(!present_arg&&sw!=manual_ack) begin manual_ack=sw;playing_bank=pb;end
            end
        end
    end
    always @(posedge clk) begin
        if(rst_n) begin
            if(present_arg) begin
                if(present_error) $fatal(1,"Copy exceeded blank interval");
                if(we&&present_busy) $fatal(1,"Video loader wrote back buffer during presentation");
                if(swap_ack==sw) playing_bank=pb;
                if(present_we) begin
                    if(present_wa!==front_pixel||present_wd!==(front_pixel^(front_frame?16'h55aa:0)))
                        $fatal(1,"Integrated copy pixel mismatch at %0d",front_pixel);
                    front_count=front_count+1;front_pixel=front_pixel+1;
                    if(front_pixel==30000) begin front_pixel=0;front_frame=single_arg?0:1-front_frame;end
                end
            end
            if(dut.level>1024) $fatal(1,"FIFO overflow");
            if(we) begin
                if(pv&&(wb==playing_bank)) $fatal(1,"Write into displayed framebuffer");
                if(wa!==expected_pixel) $fatal(1,"Pixel address %d expected %d",wa,expected_pixel);
                if(wd!==(expected_pixel^(expected_frame?16'h55aa:0))) $fatal(1,"Pixel value mismatch");
                expected_pixel=expected_pixel+1;vcnt=vcnt+1;
                if(expected_pixel==30000) begin expected_pixel=0;expected_frame=single_arg?0:1-expected_frame;end
            end
            if(dut.pop) begin
                expected_pcm=(((a_count%6000)*137)+(single_arg?0:(((a_count/6000)%2)*8191)))&65535;
                signed_expected=expected_pcm;
                scaled_expected=signed_expected*$signed({1'b0,dut.recovery_gain});
                #1;
                if(pcm!==(scaled_expected>>>8)) begin
                    // Compare after narrowing the deliberately signed 26-bit product.
                    expected_pcm=scaled_expected>>>8;
                    if(pcm!==expected_pcm) $fatal(1,"PCM sample %d got %h expected %h",a_count,pcm,expected_pcm);
                end
                a_count=a_count+1;
                if(dynamic_arg&&a_count==9500) loop_enable=0;
                if((once_arg||dynamic_arg)&&a_count==(single_arg?6000:12000)) begin
                    if(!dut.ended) $fatal(1,"One-shot did not stop after exactly two frames");
                    stop_swap=sw;
                    repeat(20000) @(negedge clk);
                    if(req||pcm!==0||sw!==stop_swap||a_count!=(single_arg?6000:12000)||!pv)
                        $fatal(1,"Stopped clip read/swapped/played again or lost last frame");
                    if(replay_arg&&!replayed) begin
                        rst_n=0;
                        repeat(4) @(negedge clk);
                        a_count=0;expected_frame=0;expected_pixel=0;vcnt=0;
                        manual_ack=0;playing_bank=0;front_pixel=0;front_frame=0;
                        replayed=1;rst_n=1;
                    end else begin
                        if(under||err) $fatal(1,"Unexpected one-shot error");
                        $display("PASS one-shot exact %0d samples, held last frame, replay=%0d dynamic=%0d",a_count,replayed,dynamic_arg);
                        $finish;
                    end
                end
                if(a_count==30000) begin
                    if(err||under!==(stall_arg!=0)) $fatal(1,"Unexpected error / underrun");
                    if(present_arg&&front_count<150000) $fatal(1,"Too few presented frame pixels");
                    $display("PASS video slot=%0d samples=%0d pixels=%0d looped five frames",slot,a_count,vcnt);
                    $finish;
                end
            end
        end
    end
    integer i,index;
    initial begin
        if($value$plusargs("PAUSE=%d",pause_arg)) begin
            wait(a_count>=1000);@(negedge clk);
            paused=1;saved_count=a_count;saved_samples=dut.played_samples;saved_rp=dut.rp;
            repeat(10000) @(negedge clk);
            if(a_count!=saved_count||dut.played_samples!=saved_samples||dut.rp!=saved_rp||pcm!=0||under)
                $fatal(1,"Pause consumed media, retained PCM, or raised underrun");
            // Explicit counter boundary test, in addition to the real PCM sequence check.
            dut.second_samples=47999;dut.elapsed_seconds=59;dut.seconds_gray=10'd59^(10'd59>>1);
            repeat(1000) @(negedge clk);
            if(dut.elapsed_seconds!=59||dut.second_samples!=47999) $fatal(1,"Paused time advanced");
            paused=0;wait(a_count>saved_count);#2;
            if(dut.elapsed_seconds!=60||seconds_gray!=(10'd60^(10'd60>>1)))
                $fatal(1,"Time rollover 00:59 -> 01:00 failed");
            wait(dut.played_frame==1);wait(dut.played_frame==0);#2;
            if(dut.elapsed_seconds!=0||dut.second_samples!=0) $fatal(1,"Loop did not restart timestamp");
            $display("PASS pause holds PCM/sample cursor/time, resume fade, minute rollover, loop timestamp reset");
        end
    end
    reg [31:0] request_addr;
    initial begin
        if($value$plusargs("SLOT=%d",slot_arg)) begin end
        if($value$plusargs("BAD=%d",bad_arg)) begin end
        if($value$plusargs("ONCE=%d",once_arg)) begin end
        if($value$plusargs("STALL=%d",stall_arg)) begin end
        if($value$plusargs("REPLAY=%d",replay_arg)) begin end
        if($value$plusargs("DYNAMIC=%d",dynamic_arg)) begin end
        if($value$plusargs("SINGLE=%d",single_arg)) begin end
        if($value$plusargs("PRESENT=%d",present_arg)) begin end
        loop_enable=!once_arg;
        slot=slot_arg;
        if(single_arg) $readmemh("slot1_single.hex",bytes,0,78335);
        else if(slot==31) $readmemh("slot32.hex",bytes);else $readmemh("slot1.hex",bytes);
        if(bad_arg==1) bytes[0]=0;
        if($value$plusargs("CAP=%d",capacity)) begin end
        if(bad_arg==2) capacity=8388608+(slot+1)*1048576-1;
        base=8388608+slot*1048576;
        #100;rst_n=1;init_done=1;
        forever begin
            wait(req);
            if(bad_arg==2) $fatal(1,"Read issued for a slot beyond reported capacity");
            request_addr=addr;
            if((request_addr<base)||(request_addr>=base+1048576)) $fatal(1,"Out of slot request");
            repeat(2400) @(negedge clk);
            if(stall_arg&&!injected&&a_count>=2000) begin
                injected=1;repeat(140000) @(negedge clk);
            end
            for(i=0;i<((bad_arg==3)?511:((bad_arg==4)?513:512));i=i+1) begin
                @(negedge clk);
                index=(request_addr-base)*512+i;
                if(index>156159) $fatal(1,"Beyond clip length");
                if(single_arg&&index>78335) $fatal(1,"Single-frame clip read beyond last frame");
                valid=1;data=bytes[index];
                if(stall_arg&&(i%13==0)) begin
                    @(negedge clk);valid=0;repeat(3) @(negedge clk);
                end
            end
            @(negedge clk);valid=0;done=1;
            @(negedge clk);done=0;
        end
    end
    initial begin
        #2000000;
        if(bad_arg!=0) begin
            if(!err) $fatal(1,"Bad media/card not rejected");
            $display("PASS bad input rejected %d",bad_arg);$finish;
        end
        #100000000;$fatal(1,"Timeout samples=%d pixels=%d state=%d ready=%d level=%d",a_count,vcnt,dut.state,dut.ready,dut.level);
    end
endmodule
