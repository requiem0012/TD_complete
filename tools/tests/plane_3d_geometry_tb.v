`timescale 1ns/1ps
module plane_3d_geometry_tb;
 reg [9:0] x=0,y=0,p=0;
 wire [9:0] mx;wire selected;wire [2:0] shade;
 photo_transition_map dut(x,y,p,2'd1,1'b1,1'b0,mx,selected,shade);
 integer xx,yy,k,fold,flight,cx,cy,u,v,tp,tilt,av,left,span,diag,du;
 integer su,sv,sav,sdist,sdiag,m,s,checks=0,count,sx,sy,shade_bits;
 integer phases[0:6];
 real start_x,start_y,end_x,end_y;
 reg paper,shadow,bank;
 initial begin
  phases[0]=160;phases[1]=240;phases[2]=320;phases[3]=400;
  phases[4]=480;phases[5]=520;phases[6]=560;
  for(k=0;k<7;k=k+1)begin
   p=phases[k];count=0;sx=0;sy=0;shade_bits=0;
   fold=(p<320)?p:320;flight=(p<320)?0:(p-320)*2;
   cx=320+flight;cy=240-flight/2-flight/4;tilt=(fold<256)?fold:256;
   left=-320+fold/2;span=(p<320)?640-fold:320-flight/4;
   for(yy=0;yy<480;yy=yy+3)for(xx=0;xx<640;xx=xx+3)begin
    x=xx;y=yy;#1;
    u=xx-cx;tp=u*tilt;v=yy-cy+(tp>>>9);av=(v<0)?-v:v;
    diag=av*fold/128;du=u-left;
    paper=span>diag&&u>=left&&du<span-diag&&!(fold>=256&&du<32&&av<8);
    su=u-12;sv=v-22;sav=(sv<0)?-sv:sv;sdist=su-left;sdiag=sav*fold/128;
    shadow=fold>=128&&span>sdiag&&su>=left&&sdist<span-sdiag&&
           !(fold>=256&&sdist<32&&sav<8);
    m=xx;s=0;bank=1;
    if(paper)begin
     bank=0;m=320+u+(tp>>>8);if(m<0)m=0;if(m>639)m=639;
     if(fold>=80&&v< -4)m=639-m;
     if(fold>=80)s=(v<0)?1:2;
     if(fold>=192&&v>0&&av>(span>>3)&&du<(span>>1))s=5;
     if(fold>=160&&av<3)s=3;
     if(fold>=192&&span-diag-du<3)s=6;
    end else if(shadow)s=4;
    if(mx!==m||selected!==bank||shade!==s)
     $fatal(1,"Projection mismatch p=%d x=%d y=%d got=%d/%d/%d expected=%d/%d/%d",p,x,y,mx,selected,shade,m,bank,s);
    shade_bits=shade_bits|(1<<shade);checks=checks+1;
    if(!selected)begin count=count+1;sx=sx+xx;sy=sy+yy;end
   end
   if(p==320)begin
    start_x=1.0*sx/count;start_y=1.0*sy/count;
    if((shade_bits&126)!=126)$fatal(1,"Missing wing, crease, underside, edge or shadow");
   end
   if(p==480)begin
    end_x=1.0*sx/count;end_y=1.0*sy/count;
    if(end_x<start_x+100||end_y>start_y-70)$fatal(1,"Flight is not clearly upward-right");
   end
   if(p==560&&count!=0)$fatal(1,"Plane did not leave screen");
  end
  $display("PASS 3D-like plane: %d independent projection samples, signed negative Y, six depth shades, shadow, upward-right centroid and offscreen clipping",checks);
  $finish;
 end
endmodule
