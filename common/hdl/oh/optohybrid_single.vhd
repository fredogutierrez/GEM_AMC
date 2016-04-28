----------------------------------------------------------------------------------
-- Company: TAMU
-- Engineer: Evaldas Juska (evka85@gmail.com)
-- 
-- Create Date: 04/08/2016 10:43:39 AM
-- Design Name: 
-- Module Name: optohybrid_single - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use ieee.std_logic_misc.all;

library work;
use work.gth_pkg.all;
use work.ttc_pkg.all;
use work.gem_pkg.all;
use work.ipbus.all;

entity optohybrid_single is
port (
    reset_i                 : in std_logic;
    ttc_clk_i               : in t_ttc_clks;
    ttc_cmds_i              : in t_ttc_cmds;
    gth_rx_usrclk_i         : in std_logic;
    gth_tx_usrclk_i         : in std_logic;
    gth_rx_data_i           : in t_gth_rx_data;
    gth_tx_data_o           : out t_gth_tx_data;
    ipb_clk_i               : in std_logic;
    ipb_reg_miso_o          : out ipb_rbus;
    ipb_reg_mosi_i          : in ipb_wbus
);
end optohybrid_single;

architecture Behavioral of optohybrid_single is
    
    signal vfat2_t1         : t_t1;
    
    --== GTX requests ==--
    
    signal g2o_req_en       : std_logic;
    signal g2o_req_valid    : std_logic;
    signal g2o_req_data     : std_logic_vector(64 downto 0);
    
    signal o2g_req_en       : std_logic;
    signal o2g_req_data     : std_logic_vector(31 downto 0);
    signal o2g_req_error    : std_logic;    
    
    --== Tracking data ==--
    
    signal evt_en           : std_logic;
    signal evt_data         : std_logic_vector(15 downto 0);
        
begin

    -- TODO: transfer between the ttc clk and tx clk domains
    vfat2_t1.lv1a <= ttc_cmds_i.l1a;
    vfat2_t1.bc0  <= ttc_cmds_i.bc0;

    --==========================--
    --== SFP TX Tracking link ==--
    --==========================--
       
    link_tx_tracking_inst : entity work.link_tx_tracking
    port map(
        gtx_clk_i   => gth_tx_usrclk_i,   
        reset_i     => reset_i,           
        vfat2_t1_i  => vfat2_t1,        
        req_en_o    => g2o_req_en,   
        req_valid_i => g2o_req_valid,   
        req_data_i  => g2o_req_data,           
        tx_kchar_o  => gth_tx_data_o.txcharisk(1 downto 0),   
        tx_data_o   => gth_tx_data_o.txdata(15 downto 0)
    );  
    
    --==========================--
    --== SFP RX Tracking link ==--
    --==========================--
    
    link_rx_tracking_inst : entity work.link_rx_tracking
    port map(
        gtx_clk_i   => gth_rx_usrclk_i,   
        reset_i     => reset_i,           
        req_en_o    => o2g_req_en,   
        req_data_o  => o2g_req_data,   
        evt_en_o    => open,
        evt_data_o  => open,
        tk_error_o  => open,
        evt_rcvd_o  => open,
        rx_kchar_i  => gth_rx_data_i.rxcharisk(1 downto 0),   
        rx_data_i   => gth_rx_data_i.rxdata(15 downto 0)        
    );

    --============================--
    --== GTX request forwarding ==--
    --============================--
    
    link_request_inst : entity work.link_request
    port map(
        ipb_clk_i   => ipb_clk_i,
        gtx_clk_i   => gth_rx_usrclk_i,
        reset_i     => reset_i,        
        ipb_mosi_i  => ipb_reg_mosi_i,
        ipb_miso_o  => ipb_reg_miso_o,        
        tx_en_i     => g2o_req_en,
        tx_valid_o  => g2o_req_valid,
        tx_data_o   => g2o_req_data,        
        rx_en_i     => o2g_req_en,
        rx_data_i   => o2g_req_data        
    );
     
end Behavioral;