----------------------------------------------------------------------------------
-- Company: TAMU, a lot of this is taken from WU
-- Engineer: Evaldas Juska (evaldas.juska@cern.ch, evka85@gmail.com)
-- 
-- Create Date: 04/24/2016 04:52:35 AM
-- Module Name: TTC
-- Project Name: GEM_AMC
-- Description: Locks to TTC clock and decodes TTC commands from the backplane link. Also provides various controls and counters to be used for configuration, diagnostics and daq   
-- 
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

library UNISIM;
use UNISIM.VComponents.all;

use work.ctp7_utils_pkg.all;
use work.ttc_pkg.all;
use work.ipbus.all;
use work.gem_pkg.all;
use work.synchronizer.all;
use work.ttc_clocks.all;
use work.ttc_cmd.all;
use work.ipbus_slave.all;
use work.ipb_addr_decode.all;
use work.registers.all;

--============================================================================
--                                                          Entity declaration
--============================================================================

entity ttc is
    port(
        -- reset
        reset_i           : in  std_logic;

        -- TTC backplane clock and data signals
        clk_40_ttc_p_i    : in  std_logic;
        clk_40_ttc_n_i    : in  std_logic;
        ttc_data_p_i      : in  std_logic;
        ttc_data_n_i      : in  std_logic;

        -- TTC clocks (40, 80, 160, 240, 320)
        ttc_clks_o        : out t_ttc_clks;

        -- TTC commands
        ttc_cmds_o        : out t_ttc_cmds;
    
        -- DAQ counters (L1A ID, Orbit ID, BX ID)
        ttc_daq_cntrs_o   : out t_ttc_daq_cntrs;

        -- IPbus
        ipb_reset_i       : in  std_logic;
        ipb_clk_i         : in  std_logic;
        ipb_mosi_i        : in  ipb_wbus;
        ipb_miso_o        : out ipb_rbus
    );

end ttc;

--============================================================================
--                                                        Architecture section
--============================================================================
architecture ttc_arch of ttc is

    --============================================================================
    --                                                         Signal declarations
    --============================================================================

    signal reset        : std_logic;
    signal reset_local  : std_logic;

    -- clocks
    signal clk_40  : std_logic;
    signal clk_80  : std_logic;
    signal clk_160 : std_logic;
    signal clk_240 : std_logic;
    signal clk_320 : std_logic;

    -- commands
    signal ttc_cmd : std_logic_vector(7 downto 0);
    signal ttc_l1a : std_logic;

    signal l1a_cmd        : std_logic;
    signal bc0_cmd        : std_logic;
    signal ec0_cmd        : std_logic;
    signal resync_cmd     : std_logic;
    signal oc0_cmd        : std_logic;
    signal start_cmd      : std_logic;
    signal stop_cmd       : std_logic;
    signal hard_reset_cmd : std_logic;
    signal calpulse_cmd   : std_logic;
    signal test_sync_cmd  : std_logic;

    -- daq counters
    signal l1id_cnt  : std_logic_vector(23 downto 0);
    signal orbit_cnt : std_logic_vector(15 downto 0);
    signal bx_cnt    : std_logic_vector(11 downto 0);

    -- control and status
    signal ttc_ctrl         : t_ttc_ctrl;
    signal ttc_status       : t_ttc_status;
    signal ttc_conf         : t_ttc_conf; 

    -- stats
    constant C_NUM_OF_DECODED_TTC_CMDS : integer := 10;
    signal ttc_cmds_arr              : std_logic_vector(C_NUM_OF_DECODED_TTC_CMDS - 1 downto 0);
    signal ttc_cmds_cnt_arr          : t_slv_arr_32(C_NUM_OF_DECODED_TTC_CMDS - 1 downto 0);

    -- ttc mini spy
    signal ttc_spy_buffer    : std_logic_vector(31 downto 0) := (others => '1');
    signal ttc_spy_pointer   : integer range 0 to 31         := 0;
    signal ttc_spy_reset     : std_logic                     := '0';

    ------ Register signals begin (this section is generated by <gem_amc_repo_root>/scripts/generate_registers.py -- do not edit)
    signal regs_read_arr        : t_std32_array(REG_TTC_NUM_REGS - 1 downto 0);
    signal regs_write_arr       : t_std32_array(REG_TTC_NUM_REGS - 1 downto 0);
    signal regs_addresses       : T_REG_TTC_ADDRESS_ARR(REG_TTC_NUM_REGS - 1 downto 0);
    signal regs_defaults        : t_std32_array(REG_TTC_NUM_REGS - 1 downto 0) := (others => '0');
    signal regs_read_pulse_arr  : std_logic_vector(REG_TTC_NUM_REGS - 1 downto 0);
    signal regs_write_pulse_arr : std_logic_vector(REG_TTC_NUM_REGS - 1 downto 0);
    ------ Register signals end ----------------------------------------------
    
--============================================================================
--                                                          Architecture begin
--============================================================================

begin
    i_reset_sync: 
    entity work.synchronizer
        generic map(
            N_STAGES => 3
        )
        port map(
            async_i => reset_i,
            clk_i   => clk_40,
            sync_o  => reset
        );

    i_ttc_clocks:
    entity work.ttc_clocks
        port map(
            clk_40_ttc_p_i       => clk_40_ttc_p_i,
            clk_40_ttc_n_i       => clk_40_ttc_n_i,
            mmcm_rst_i           => ttc_ctrl.mmcm_reset,
            mmcm_locked_o        => ttc_stat.mmcm_locked,
            ttc_mmcm_ps_clk_i    => clk_40,
            ttc_mmcm_ps_clk_en_i => ttc_ctrl.mmcm_phase_shift,
            clk_40_bufg_o        => clk_40,
            clk_80_bufg_o        => clk_80,
            clk_160_bufg_o       => clk_160,
            clk_240_bufg_o       => clk_240,
            clk_320_bufg_o       => clk_320
        );

    i_ttc_cmd:
    entity work.ttc_cmd
        port map(
            clk_40_i             => clk_40,
            ttc_data_p_i         => ttc_data_p_i,
            ttc_data_n_i         => ttc_data_n_i,
            ttc_cmd_o            => ttc_cmd,
            ttc_l1a_o            => ttc_l1a,
            tcc_err_cnt_rst_i    => ttc_ctrl_i.stat_reset or reset,
            ttc_err_single_cnt_o => ttc_status.single_err,
            ttc_err_double_cnt_o => ttc_status.double_err
        );

    p_cmd:
    process(clk_40) is
    begin
        if (rising_edge(clk_40)) then
            if (reset = '1') then
                bc0_cmd        <= '0';
                ec0_cmd        <= '0';
                resync_cmd     <= '0';
                oc0_cmd        <= '0';
                start_cmd      <= '0';
                stop_cmd       <= '0';
                test_sync_cmd  <= '0';
                hard_reset_cmd <= '0';
                calpulse_cmd   <= '0';
                l1a_cmd        <= '0';
            else
                if (ttc_cmd = ttc_conf.cmd_bc0) then
                    bc0_cmd <= '1';
                else
                    bc0_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_ec0) then
                    ec0_cmd <= '1';
                else
                    ec0_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_resync) then
                    resync_cmd <= '1';
                else
                    resync_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_oc0) then
                    oc0_cmd <= '1';
                else
                    oc0_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_hard_reset) then
                    s_hart_reset_cmd <= '1';
                else
                    hard_reset_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_calpulse) then
                    calpulse_cmd <= '1';
                else
                    calpulse_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_start) then
                    start_cmd <= '1';
                else
                    start_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_stop) then
                    stop_cmd <= '1';
                else
                    stop_cmd <= '0';
                end if;
                if (ttc_cmd = ttc_conf.cmd_test_sync) then
                    test_sync_cmd <= '1';
                else
                    test_sync_cmd <= '0';
                end if;

                l1a_cmd <= ttc_l1a and ttc_ctrl.l1a_enable;

            end if;

        end if;
    end process p_cmd;

    p_orbit_cnt:
    process(clk_40) is
    begin
        if (rising_edge(clk_40)) then
            if (reset = '1') then
                orbit_cnt <= (others => '0');
            else
                if (oc0_cmd = '1') then
                    orbit_cnt <= (others => '0');
                elsif (bc0_cmd = '1') then
                    orbit_cnt <= std_logic_vector(unsigned(orbit_cnt) + 1);
                end if;
            end if;

        end if;
    end process p_orbit_cnt;

    p_l1id_cnt:
    process(clk_40) is
    begin
        if (rising_edge(clk_40)) then
            if (reset = '1') then
                l1id_cnt <= (others => '0');
            else
                if (ec0_cmd = '1') then
                    l1id_cnt <= (others => '0');
                elsif (l1a_cmd = '1') then
                    l1id_cnt <= std_logic_vector(unsigned(l1id_cnt) + 1);
                end if;
            end if;

        end if;
    end process p_l1id_cnt;

    p_bx_cnt:
    process(clk_40) is
    begin
        if (rising_edge(clk_40)) then
            if (reset = '1') then
                bc0_cmd <= (others => '0');
            else
                if (bc0_cmd = '1') then
                    s_bc_cnt <= (others => '0');
                else
                    bx_cnt <= std_logic_vector(unsigned(bx_cnt) + 1);
                end if;
            end if;

        end if;
    end process bx_cnt;

    p_mini_spy:
    process(clk_40) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
            else
            end if;
        end if;
    end process mini_spy;

    ttc_daq_cntrs_o.orbit <= orbit_cnt;
    ttc_daq_cntrs_o.l1id  <= l1id_cnt;
    ttc_daq_cntrs_o.bx    <= bx_cnt;

    ttc_cmds_arr(0) <= l1a_cmd;
    ttc_cmds_arr(1) <= bc0_cmd;
    ttc_cmds_arr(2) <= ec0_cmd;
    ttc_cmds_arr(3) <= resync_cmd;
    ttc_cmds_arr(4) <= oc0_cmd;
    ttc_cmds_arr(5) <= hard_reset_cmd;
    ttc_cmds_arr(6) <= calpulse_cmd;
    ttc_cmds_arr(7) <= start_cmd;
    ttc_cmds_arr(8) <= stop_cmd;
    ttc_cmds_arr(9) <= test_sync_cmd;

    gen_ttc_cmd_cnt:
    for i in 0 to C_NUM_OF_DECODED_TTC_CMDS - 1 generate
        process(clk_40) is
        begin
            if (rising_edge(clk_40)) then
                if (ttc_ctrl.stat_reset = '1' or reset = '1') then
                    ttc_cmds_cnt_arr(i) <= (others => '0');
                elsif (ttc_cmds_arr(i) = '1') then
                    ttc_cmds_cnt_arr(i) <= std_logic_vector(unsigned(ttc_cmds_cnt_arr(i)) + 1);
                end if;
            end if;
        end process;
    end generate;

    ttc_cmds_o.l1a        <= l1a_cmd;
    ttc_cmds_o.bc0        <= bc0_cmd;
    ttc_cmds_o.ec0        <= ec0_cmd;
    ttc_cmds_o.resync     <= resync_cmd;
    ttc_cmds_o.hard_reset <= hard_reset_cmd;
    ttc_cmds_o.calpulse   <= calpulse_cmd;
    ttc_cmds_o.start      <= start_cmd;
    ttc_cmds_o.stop       <= stop_cmd;
    ttc_cmds_o.test_sync  <= test_sync_cmd;

    ttc_clks_o.clk_40  <= clk_40;
    ttc_clks_o.clk_80  <= clk_80;
    ttc_clks_o.clk_160 <= clk_160;
    ttc_clks_o.clk_240 <= clk_240;
    ttc_clks_o.clk_320 <= clk_320;

    --===============================================================================================
    -- this section is generated by <gem_amc_repo_root>/scripts/generate_registers.py (do not edit) 
    --==== Registers begin ==========================================================================

    -- IPbus slave instanciation
    ipbus_slave_inst : entity work.ipbus_slave
        generic map(
           g_NUM_REGS             => REG_TTC_NUM_REGS,
           g_ADDR_HIGH_BIT        => REG_TTC_ADDRESS_MSB,
           g_ADDR_LOW_BIT         => REG_TTC_ADDRESS_LSB,
           g_USE_INDIVIDUAL_ADDRS => "TRUE"
       )
       port map(
           ipb_reset_i            => ipb_reset_i,
           ipb_clk_i              => ipb_clk_i,
           ipb_mosi_i             => ipb_mosi_i,
           ipb_miso_o             => ipb_miso_o,
           usr_clk_i              => clk_40,
           regs_read_arr_i        => regs_read_arr,
           regs_write_arr_o       => regs_write_arr,
           read_pulse_arr_o       => regs_read_pulse_arr,
           write_pulse_arr_o      => regs_write_pulse_arr,
           individual_addrs_arr_i => regs_addresses,
           regs_defaults_arr_i    => regs_defaults
      );

    -- Connect read signals
    regs_read_arr(REG_TTC_CTRL_L1A_ENABLE_BIT) <= ttc_ctrl.l1a_enable;
    regs_read_arr(REG_TTC_CONFIG_CMD_BC0_MSB downto REG_TTC_CONFIG_CMD_BC0_LSB) <= ttc_conf.bc0_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_EC0_MSB downto REG_TTC_CONFIG_CMD_EC0_LSB) <= ttc_conf.ec0_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_RESYNC_MSB downto REG_TTC_CONFIG_CMD_RESYNC_LSB) <= ttc_conf.resync_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_OC0_MSB downto REG_TTC_CONFIG_CMD_OC0_LSB) <= ttc_conf.oc0_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_HARD_RESET_MSB downto REG_TTC_CONFIG_CMD_HARD_RESET_LSB) <= ttc_conf.hard_reset_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_CALPULSE_MSB downto REG_TTC_CONFIG_CMD_CALPULSE_LSB) <= ttc_conf.calpulse_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_START_MSB downto REG_TTC_CONFIG_CMD_START_LSB) <= ttc_conf.start_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_STOP_MSB downto REG_TTC_CONFIG_CMD_STOP_LSB) <= ttc_conf.stop_cmd;
    regs_read_arr(REG_TTC_CONFIG_CMD_TEST_SYNC_MSB downto REG_TTC_CONFIG_CMD_TEST_SYNC_LSB) <= ttc_conf.test_sync_cmd;
    regs_read_arr(REG_TTC_STATUS_MMCM_LOCKED_BIT) <= ttc_status.mmcm_locked;
    regs_read_arr(REG_TTC_STATUS_TTC_SINGLE_ERROR_CNT_MSB downto REG_TTC_STATUS_TTC_SINGLE_ERROR_CNT_LSB) <= ttc_status.single_err;
    regs_read_arr(REG_TTC_STATUS_TTC_DOUBLE_ERROR_CNT_MSB downto REG_TTC_STATUS_TTC_DOUBLE_ERROR_CNT_LSB) <= ttc_status.double_err;
    regs_read_arr(REG_TTC_STATUS_BC0_LOCKED_BIT) <= ttc_status.bc0_status.locked;
    regs_read_arr(REG_TTC_STATUS_BC0_UNLOCK_CNT_MSB downto REG_TTC_STATUS_BC0_UNLOCK_CNT_LSB) <= ttc_status.bc0_status.unlocked_cnt;
    regs_read_arr(REG_TTC_STATUS_BC0_OVERFLOW_CNT_MSB downto REG_TTC_STATUS_BC0_OVERFLOW_CNT_LSB) <= ttc_status.bc0_status.ovf_cnt;
    regs_read_arr(REG_TTC_STATUS_BC0_UNDERFLOW_CNT_MSB downto REG_TTC_STATUS_BC0_UNDERFLOW_CNT_LSB) <= ttc_status.bc0_status.udf_cnt;
    regs_read_arr(REG_TTC_CMD_COUNTERS_L1A_MSB downto REG_TTC_CMD_COUNTERS_L1A_LSB) <= ttc_cmds_cnt_arr(0);
    regs_read_arr(REG_TTC_CMD_COUNTERS_BC0_MSB downto REG_TTC_CMD_COUNTERS_BC0_LSB) <= ttc_cmds_cnt_arr(1);
    regs_read_arr(REG_TTC_CMD_COUNTERS_EC0_MSB downto REG_TTC_CMD_COUNTERS_EC0_LSB) <= ttc_cmds_cnt_arr(2);
    regs_read_arr(REG_TTC_CMD_COUNTERS_RESYNC_MSB downto REG_TTC_CMD_COUNTERS_RESYNC_LSB) <= ttc_cmds_cnt_arr(3);
    regs_read_arr(REG_TTC_CMD_COUNTERS_OC0_MSB downto REG_TTC_CMD_COUNTERS_OC0_LSB) <= ttc_cmds_cnt_arr(4);
    regs_read_arr(REG_TTC_CMD_COUNTERS_HARD_RESET_MSB downto REG_TTC_CMD_COUNTERS_HARD_RESET_LSB) <= ttc_cmds_cnt_arr(5);
    regs_read_arr(REG_TTC_CMD_COUNTERS_CALPULSE_MSB downto REG_TTC_CMD_COUNTERS_CALPULSE_LSB) <= ttc_cmds_cnt_arr(6);
    regs_read_arr(REG_TTC_CMD_COUNTERS_START_MSB downto REG_TTC_CMD_COUNTERS_START_LSB) <= ttc_cmds_cnt_arr(7);
    regs_read_arr(REG_TTC_CMD_COUNTERS_STOP_MSB downto REG_TTC_CMD_COUNTERS_STOP_LSB) <= ttc_cmds_cnt_arr(8);
    regs_read_arr(REG_TTC_CMD_COUNTERS_TEST_SYNC_MSB downto REG_TTC_CMD_COUNTERS_TEST_SYNC_LSB) <= ttc_cmds_cnt_arr(9);
    regs_read_arr(REG_TTC_L1A_ID_MSB downto REG_TTC_L1A_ID_LSB) <= bx_cnt;
    regs_read_arr(REG_TTC_TTC_SPY_BUFFER_MSB downto REG_TTC_TTC_SPY_BUFFER_LSB) <= ttc_spy_buffer;

    -- Connect write signals
    ttc_ctrl.l1a_enable <= regs_write_arr(REG_TTC_CTRL_L1A_ENABLE_BIT);
    ttc_ctrl.mmcm_phase_shift <= regs_write_arr(REG_TTC_CTRL_MMCM_PHASE_SHIFT_BIT);
    ttc_ctrl.cnt_reset <= regs_write_arr(REG_TTC_CTRL_CNT_RESET_BIT);
    ttc_ctrl.mmcm_reset <= regs_write_arr(REG_TTC_CTRL_MMCM_RESET_BIT);
    ttc_ctrl.reset_local <= regs_write_arr(REG_TTC_CTRL_MODULE_RESET_BIT);
    ttc_conf.bc0_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_BC0_MSB downto REG_TTC_CONFIG_CMD_BC0_LSB);
    ttc_conf.ec0_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_EC0_MSB downto REG_TTC_CONFIG_CMD_EC0_LSB);
    ttc_conf.resync_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_RESYNC_MSB downto REG_TTC_CONFIG_CMD_RESYNC_LSB);
    ttc_conf.oc0_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_OC0_MSB downto REG_TTC_CONFIG_CMD_OC0_LSB);
    ttc_conf.hard_reset_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_HARD_RESET_MSB downto REG_TTC_CONFIG_CMD_HARD_RESET_LSB);
    ttc_conf.calpulse_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_CALPULSE_MSB downto REG_TTC_CONFIG_CMD_CALPULSE_LSB);
    ttc_conf.start_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_START_MSB downto REG_TTC_CONFIG_CMD_START_LSB);
    ttc_conf.stop_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_STOP_MSB downto REG_TTC_CONFIG_CMD_STOP_LSB);
    ttc_conf.test_sync_cmd <= regs_write_arr(REG_TTC_CONFIG_CMD_TEST_SYNC_MSB downto REG_TTC_CONFIG_CMD_TEST_SYNC_LSB);

    -- Addresses
    regs_addresses(0) <= "00" & x"0";
    regs_addresses(1) <= "00" & x"1";
    regs_addresses(2) <= "00" & x"2";
    regs_addresses(3) <= "00" & x"3";
    regs_addresses(4) <= "00" & x"4";
    regs_addresses(5) <= "00" & x"5";
    regs_addresses(6) <= "00" & x"6";
    regs_addresses(7) <= "00" & x"7";
    regs_addresses(8) <= "00" & x"8";
    regs_addresses(9) <= "00" & x"9";
    regs_addresses(10) <= "00" & x"a";
    regs_addresses(11) <= "00" & x"b";
    regs_addresses(12) <= "00" & x"c";
    regs_addresses(13) <= "00" & x"d";
    regs_addresses(14) <= "00" & x"e";
    regs_addresses(15) <= "00" & x"f";
    regs_addresses(16) <= "01" & x"0";
    regs_addresses(17) <= "01" & x"1";
    regs_addresses(18) <= "01" & x"2";
    regs_addresses(19) <= "01" & x"3";
    regs_addresses(20) <= "01" & x"4";

    -- Defaults
    regs_defaults(REG_TTC_CTRL_L1A_ENABLE_BIT) <= REG_TTC_CTRL_L1A_ENABLE_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_BC0_MSB downto REG_TTC_CONFIG_CMD_BC0_LSB) <= REG_TTC_CONFIG_CMD_BC0_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_EC0_MSB downto REG_TTC_CONFIG_CMD_EC0_LSB) <= REG_TTC_CONFIG_CMD_EC0_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_RESYNC_MSB downto REG_TTC_CONFIG_CMD_RESYNC_LSB) <= REG_TTC_CONFIG_CMD_RESYNC_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_OC0_MSB downto REG_TTC_CONFIG_CMD_OC0_LSB) <= REG_TTC_CONFIG_CMD_OC0_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_HARD_RESET_MSB downto REG_TTC_CONFIG_CMD_HARD_RESET_LSB) <= REG_TTC_CONFIG_CMD_HARD_RESET_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_CALPULSE_MSB downto REG_TTC_CONFIG_CMD_CALPULSE_LSB) <= REG_TTC_CONFIG_CMD_CALPULSE_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_START_MSB downto REG_TTC_CONFIG_CMD_START_LSB) <= REG_TTC_CONFIG_CMD_START_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_STOP_MSB downto REG_TTC_CONFIG_CMD_STOP_LSB) <= REG_TTC_CONFIG_CMD_STOP_DEFAULT;
    regs_defaults(REG_TTC_CONFIG_CMD_TEST_SYNC_MSB downto REG_TTC_CONFIG_CMD_TEST_SYNC_LSB) <= REG_TTC_CONFIG_CMD_TEST_SYNC_DEFAULT;

    --==== Registers end ============================================================================

end ttc_arch;
--============================================================================
--                                                            Architecture end
--============================================================================