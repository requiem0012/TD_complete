`timescale 1ns/1ps
module EG_PHY_SDRAM_2M_32(
 input clk,ras_n,cas_n,we_n,cs_n,cke,dm0,dm1,dm2,dm3,
 input [10:0] addr,input [1:0] ba,inout [31:0] dq);
 IS42s32200 memory(.Clk(clk),.Ras_n(ras_n),.Cas_n(cas_n),.We_n(we_n),
  .Cs_n(cs_n),.Cke(cke),.Dqm({dm3,dm2,dm1,dm0}),.Addr(addr),.Ba(ba),.Dq(dq));
endmodule
