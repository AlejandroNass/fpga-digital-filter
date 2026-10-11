-- ============================================================================
-- tb_proyecto_filtro_top.vhd
-- Testbench para simular la cadena completa:
--   ADC (señal DC + ruido) -> proyecto_filtro_top -> DAC R2R
--
-- Estímulo:
--   * De 0 a 8 ms : nivel DC = 160 + ruido aleatorio de +/- 20
--   * De 8 a 12 ms: nivel DC = 96  + ruido aleatorio de +/- 20 (escalón)
--   * Fs del filtro = 20 kHz (muestras cada 50 us)
--
-- Resultado esperado:
--   dac_out debe seguir el nivel DC (~160 y luego ~96) con el ruido atenuado.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_proyecto_filtro_top is
end tb_proyecto_filtro_top;

architecture sim of tb_proyecto_filtro_top is

    constant CLK_PERIOD : time := 20 ns;   -- 50 MHz

    signal clk_50MHz   : std_logic := '0';
    signal rst         : std_logic := '1';
    signal ps2_clk     : std_logic := '1';
    signal ps2_data    : std_logic := '1';
    signal encoder_in  : std_logic := '0';
    signal adc_in      : std_logic_vector(7 downto 0) := (others => '0');

    signal pwm_out     : std_logic;
    signal dac_out     : std_logic_vector(7 downto 0);

    signal seg_millares : std_logic_vector(6 downto 0);
    signal seg_centenas : std_logic_vector(6 downto 0);
    signal seg_decenas  : std_logic_vector(6 downto 0);
    signal seg_unidades : std_logic_vector(6 downto 0);
    signal ext_seg_millares : std_logic_vector(6 downto 0);
    signal ext_seg_centenas : std_logic_vector(6 downto 0);
    signal ext_seg_decenas  : std_logic_vector(6 downto 0);
    signal ext_seg_unidades : std_logic_vector(6 downto 0);

    -- LFSR de 16 bits para generar ruido pseudoaleatorio
    signal lfsr      : std_logic_vector(15 downto 0) := x"ACE1";
    signal noise_val : signed(7 downto 0) := (others => '0');

begin

    ----------------------------------------------------------------------------
    -- Reloj de 50 MHz
    ----------------------------------------------------------------------------
    clk_50MHz <= not clk_50MHz after CLK_PERIOD / 2;

    ----------------------------------------------------------------------------
    -- Reset
    ----------------------------------------------------------------------------
    process
    begin
        rst <= '1';
        wait for 300 ns;
        rst <= '0';
        wait;
    end process;

    ----------------------------------------------------------------------------
    -- Unidad bajo prueba
    ----------------------------------------------------------------------------
    uut : entity work.proyecto_filtro_top
        port map (
            clk_50MHz        => clk_50MHz,
            rst              => rst,
            ps2_clk          => ps2_clk,
            ps2_data         => ps2_data,
            encoder_in       => encoder_in,
            adc_in           => adc_in,
            pwm_out          => pwm_out,
            dac_out          => dac_out,
            seg_millares     => seg_millares,
            seg_centenas     => seg_centenas,
            seg_decenas      => seg_decenas,
            seg_unidades     => seg_unidades,
            ext_seg_millares => ext_seg_millares,
            ext_seg_centenas => ext_seg_centenas,
            ext_seg_decenas  => ext_seg_decenas,
            ext_seg_unidades => ext_seg_unidades
        );

    ----------------------------------------------------------------------------
    -- LFSR: ruido pseudoaleatorio
    ----------------------------------------------------------------------------
    process(clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
        end if;
    end process;

    -- Ruido en el rango -20 .. +20
    noise_val <= to_signed((to_integer(unsigned(lfsr(7 downto 0))) mod 41) - 20, 8);

    ----------------------------------------------------------------------------
    -- Estímulo ADC: DC + ruido, con escalón de 160 a 96 en t = 8 ms
    ----------------------------------------------------------------------------
    process(noise_val)
        variable base : integer := 160;
    begin
        if now < 8000 us then
            base := 160;
        else
            base := 96;
        end if;
        adc_in <= std_logic_vector(to_unsigned(base + to_integer(noise_val), 8));
    end process;

    ----------------------------------------------------------------------------
    -- Reporte del valor DAC cada periodo de muestreo (50 us)
    ----------------------------------------------------------------------------
    process(clk_50MHz)
        variable cnt        : integer := 0;
        variable report_cnt : integer := 0;
    begin
        if rising_edge(clk_50MHz) then
            if rst = '0' then
                if cnt = 2499 then
                    cnt := 0;
                    report "t=" & time'image(now) &
                           "  dac_out=" & integer'image(to_integer(unsigned(dac_out))) &
                           "  filtrado_display=" & integer'image(to_integer(unsigned(dac_out)) * 260 / 255);
                    report_cnt := report_cnt + 1;
                else
                    cnt := cnt + 1;
                end if;
            end if;
        end if;
    end process;

end sim;
