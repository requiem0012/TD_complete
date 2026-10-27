`timescale 1ns/1ps
// Real A/B RAM outputs + one bilinear scaler, including the moving bank seam.
module photo_push_render_tb;
    reg wc=0,rc=0;always #10 wc=~wc;always #20 rc=~rc;
    reg reset_n=0,we=0,front=0;
    reg [14:0] wa=0;
    reg [9:0] tx=0,ty=0,offset=0;
    wire [12:0] a0,a1,a2,a3;
    wire [15:0] p0,p1,p2,p3,q0,q1,q2,q3;
    wire [7:0] r,g,b;
    wire selected;
    framebuffer a(wc,we,wa,{1'b0,wa},rc,a0,a1,a2,a3,p0,p1,p2,p3,13'd0,,,,);
    framebuffer #(.USE_32K(1),.AUX_READ(1)) z(wc,we,wa,({1'b0,wa}^16'h55aa),rc,
        a0,a1,a2,a3,q0,q1,q2,q3,13'd0,,,,);
    vga_disp #(.ENABLE_SLIDE(1)) scale(rc,reset_n,tx,ty,
        selected?q0:p0,selected?q1:p1,selected?q2:p2,selected?q3:p3,
        a0,a1,a2,a3,r,g,b,offset,front,1'b1,selected);
    integer i,x,y,k,ox,oy,checked,shift_case;
    reg [23:0] current,previous;
    reg previous_active;
    function [7:0] channel;
        input integer x,y,c,seed;
        reg [15:0] v;
        begin
            v=(y*200+x)^seed;
            case(c)
                0:channel={v[15:11],v[15:13]};
                1:channel={v[10:5],v[10:9]};
                2:channel={v[4:0],v[4:2]};
            endcase
        end
    endfunction
    function [23:0] reference;
        input integer x,y;
        integer mx,bank,seed,sx,sy,nx,ny,fx,fy,c,t,d,value;
        begin
            mx=x+offset;bank=front;
            if(mx>=640) begin mx=mx-640;bank=1-bank;end
            seed=bank?16'h55aa:0;
            sx=mx*5/16;sy=y*5/16;fx=mx*5%16;fy=y*5%16;
            nx=(sx==199)?199:sx+1;ny=(sy==149)?149:sy+1;
            for(c=0;c<3;c=c+1) begin
                t=channel(sx,sy,c,seed)*(16-fx)+channel(nx,sy,c,seed)*fx;
                d=channel(sx,ny,c,seed)*(16-fx)+channel(nx,ny,c,seed)*fx;
                value=(t*(16-fy)+d*fy+128)>>8;
                reference[23-c*8-:8]=value;
            end
        end
    endfunction
    task point;
        input integer x,y;
        begin
            @(negedge rc);
            tx=(x==0)?799:x-1;ty=(x==0)?((y==0)?524:y-1):y;
            repeat(2) @(posedge rc);#1;
            if({r,g,b}!==reference(x,y))
                $fatal(1,"Moving seam mismatch front=%0d offset=%0d x=%0d y=%0d got=%h expected=%h",front,offset,x,y,{r,g,b},reference(x,y));
        end
    endtask
    initial begin
        for(i=0;i<30000;i=i+1) begin @(negedge wc);we=1;wa=i;end
        @(negedge wc);we=0;
        repeat(3) @(negedge rc);reset_n=1;
        // All 641 positions, both ownership directions, edges and seam neighbours.
        for(shift_case=0;shift_case<2;shift_case=shift_case+1) begin
            front=shift_case;
            for(k=0;k<=640;k=k+1) begin
                offset=k;
                for(y=0;y<3;y=y+1) begin
                    point(0,y==2?479:y);point(639,y==2?479:y);
                    for(x=-2;x<=2;x=x+1)
                        if(640-k+x>=0&&640-k+x<640) point(640-k+x,y==2?479:y);
                end
            end
        end
        $display("PASS every slide offset 0..640, both A/B owners, seam +/-2, frame and clamp edges");
        for(shift_case=0;shift_case<4;shift_case=shift_case+1) begin
            front=shift_case%2;
            case(shift_case) 0:offset=0;1:offset=1;2:offset=319;3:offset=639;endcase
            reset_n=0;repeat(3) @(negedge rc);reset_n=1;
            previous_active=0;checked=0;
            for(i=0;i<420001;i=i+1) begin
                @(negedge rc);tx=i%800;ty=(i/800)%525;
                ox=(tx==799)?0:tx+1;oy=(tx==799)?((ty==524)?0:ty+1):ty;
                current=reference(ox<640?ox:0,oy<480?oy:0);
                @(posedge rc);#1;
                if(previous_active) begin
                    if({r,g,b}!==previous) $fatal(1,"Push raster offset=%0d front=%0d pixel=%0d got=%h expected=%h",offset,front,i,{r,g,b},previous);
                    checked=checked+1;
                end
                previous=current;previous_active=(i<420000)&&(ox<640)&&(oy<480);
            end
            if(checked!=307200) $fatal(1,"Push pixel count mismatch");
            $display("PASS photo push offset=%0d front=%0d all 307200 RGB888 pixels",offset,front);
        end
        $finish;
    end
endmodule
