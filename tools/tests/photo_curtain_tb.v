`timescale 1ns/1ps
module photo_curtain_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=0,blank=0,loaded=1,n=0,p=0,ack=0;
    wire nl,pl,req,event_out;
    wire [9:0] width;
    wire [31:0] base;
    integer ticks=0,nav=0;
    photo_curtain dut(clk,rst,blank,loaded,n,p,nl,pl,width);
    image_controller control(.clk(clk),.rst_n(rst),.sd_init_done(1'b1),
        .key_press(nl),.previous_press(pl),.load_ack(ack),.load_req(req),
        .base_sector(base),.switch_event(event_out));
    always @(negedge clk) if(rst) begin
        ticks=ticks+1;blank=(ticks%20>=10);
        if(nl||pl) begin
            nav=nav+1;
            if(width!=640) $fatal(1,"Loader started before curtain fully covered");
        end
    end
    task press_previous;
        begin @(negedge clk);p=1;@(negedge clk);p=0;end
    endtask
    initial begin
        #100;rst=1;repeat(6) @(negedge clk);ack=1;
        repeat(2) @(negedge clk);ack=0;
        press_previous;
        repeat(100) @(negedge clk);
        if(width==0||width==640||req) $fatal(1,"Close progress/early load failed");
        n=1;@(negedge clk);n=0; // Ignore navigation while an animation owns the loader.
        wait(pl);repeat(3) @(negedge clk);
        if(base!=384||nav!=1) $fatal(1,"Previous photo must wrap 0 -> 3 exactly once");
        ack=1;loaded=0;repeat(200) @(negedge clk);
        if(width!=640) $fatal(1,"Curtain opened during an incomplete load");
        ack=0;loaded=1;wait(dut.phase==0);#1;
        if(width!=0||nav!=1) $fatal(1,"Open/ignored navigation failed");
        @(negedge clk);n=1;@(negedge clk);n=0;
        wait(nl);repeat(3) @(negedge clk);
        if(base!=0||nav!=2) $fatal(1,"Next photo must wrap 3 -> 0");
        loaded=0;repeat(10) @(negedge clk);rst=0;#1;
        if(width!=0||req) $fatal(1,"Reset did not cancel pending animation/load");
        $display("PASS photo curtain 45+45 refreshes, opaque load hold, previous/next wrap and busy/reset");
        $finish;
    end
    initial begin #200000;$fatal(1,"Curtain timeout");end
endmodule
