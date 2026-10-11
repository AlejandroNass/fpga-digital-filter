-- ============================================================================
-- proyecto_filtro_top.vhd
-- Proyecto completo - Examen Parcial - Electrónica Digital II (UPTC)
-- Tarjeta: FPGA DE1 (Altera Cyclone II EP2C20)
--
-- Integra TODA la cadena del sistema:
--   1. Teclado PS/2          -> referencia de velocidad del usuario (0..260)
--   2. PWM ~1 kHz            -> control del motor (driver)
--   3. Encoder (1 pulso/rev) -> medición de RPS reales (opcional en display)
--   4. Entrada ADC 8 bits    -> (Arduino PORTD, sensor/generador con ruido)
--   5. Filtro FIR pasabajas  -> filtropb (21 coeficientes, MATLAB HDL Coder)
--   6. Salida DAC R2R 8 bits -> osciloscopio
--   7. Displays 7 segmentos  -> usuario (4 dígitos) + medición (4 dígitos)
--
-- Frecuencia de muestreo del filtro: Fs = 20 kHz
--   clk_enable = tick cada 50_000_000 / 20_000 = 2_500 ciclos de reloj
--
-- Escalamiento de datos (clave para conectar ADC y DAC reales):
--   * El filtro MATLAB usa entrada sfix8_En15 y salida sfix27_En33.
--   * Entrada:  la muestra sin signo del ADC (0..255) se CENTRA restándole 128,
--               quedando como valor con signo (-128..127) que el filtro entiende.
--   * Salida:   filter_out(26 downto 18) = valor/2^18. Se le suma 128 (offset)
--               y se satura a 0..255 para el DAC R2R.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity proyecto_filtro_top is
    port (
        clk_50MHz        : in  std_logic;
        rst              : in  std_logic;                      -- reset activo en '1'
        -- Teclado PS/2
        ps2_clk          : in  std_logic;
        ps2_data         : in  std_logic;
        -- Entrada Encoder (1 ranura = 1 pulso por revolución)
        encoder_in       : in  std_logic;
        -- Entrada ADC 8 bits desde Arduino (PORTD)
        adc_in           : in  std_logic_vector(7 downto 0);
        -- Salida PWM para el motor
        pwm_out          : out std_logic;
        -- Salida DAC R2R 8 bits
        dac_out          : out std_logic_vector(7 downto 0);
        -- Displays Usuario (ánodo común, activo en '0') - 4 dígitos
        seg_millares     : out std_logic_vector(6 downto 0);   -- primer display (apagado)
        seg_centenas     : out std_logic_vector(6 downto 0);
        seg_decenas      : out std_logic_vector(6 downto 0);
        seg_unidades     : out std_logic_vector(6 downto 0);
        -- Displays Medición (cátodo común, activo en '1') - 4 dígitos
        ext_seg_millares : out std_logic_vector(6 downto 0);
        ext_seg_centenas : out std_logic_vector(6 downto 0);
        ext_seg_decenas  : out std_logic_vector(6 downto 0);
        ext_seg_unidades : out std_logic_vector(6 downto 0)
    );
end proyecto_filtro_top;

architecture Behavioral of proyecto_filtro_top is

    ----------------------------------------------------------------------------
    -- Componente: filtro FIR generado por MATLAB (NO modificar)
    ----------------------------------------------------------------------------
    component filtropb is
        port (
            clk         : in  std_logic;
            clk_enable  : in  std_logic;
            reset       : in  std_logic;
            filter_in   : in  std_logic_vector(7 downto 0);   -- sfix8_En15
            filter_out  : out std_logic_vector(26 downto 0)   -- sfix27_En33
        );
    end component;

    ----------------------------------------------------------------------------
    -- Constantes de configuración
    ----------------------------------------------------------------------------
    -- Fs = 20 kHz => divisor = (50 MHz / 20 kHz) - 1 = 2499
    constant FS_DIVIDER            : integer := 2499;
    -- TRUE  -> display de medición muestra el valor FILTRADO del ADC (lo pide el examen)
    -- FALSE -> display de medición muestra los RPS medidos por el encoder
    constant MEASURE_SOURCE_FILTERED : boolean := TRUE;
    -- Escala máxima del valor filtrado mostrado (misma escala que la referencia 0..260)
    constant FILTER_SCALE_MAX      : integer := 260;

    ----------------------------------------------------------------------------
    -- Señales PWM
    ----------------------------------------------------------------------------
    signal div_cnt    : integer range 0 to 191 := 0;
    signal tick_pwm   : std_logic := '0';
    signal cnt_mod260 : integer range 0 to 260 := 0;

    ----------------------------------------------------------------------------
    -- Señales PS/2
    ----------------------------------------------------------------------------
    signal ps2_clk_sync  : std_logic_vector(2 downto 0) := (others => '1');
    signal ps2_data_sync : std_logic_vector(1 downto 0) := (others => '1');
    signal ps2_fall_edge : std_logic := '0';
    signal ps2_shift_reg : std_logic_vector(10 downto 0) := (others => '1');
    signal bit_cnt       : integer range 0 to 10 := 0;
    signal rx_done       : std_logic := '0';
    signal scancode      : std_logic_vector(7 downto 0) := (others => '0');

    type state_type is (WAIT_DIGIT1, WAIT_DIGIT2, WAIT_DIGIT3, WAIT_ENTER);
    signal state        : state_type := WAIT_DIGIT1;
    signal is_break     : std_logic := '0';
    signal digit1       : integer range 0 to 9 := 0;
    signal digit2       : integer range 0 to 9 := 0;
    signal digit3       : integer range 0 to 9 := 0;
    -- Filtro anti-repetición (typematic) del teclado
    signal last_make    : std_logic_vector(7 downto 0) := (others => '0');
    signal make_pending : std_logic := '0';   -- '1' = tecla aún presionada

    signal ref_val  : integer range 0 to 260 := 0;
    signal pwm_duty : integer range 0 to 260 := 0;

    ----------------------------------------------------------------------------
    -- Señales Encoder (RPS)
    ----------------------------------------------------------------------------
    signal enc_sync     : std_logic_vector(2 downto 0) := (others => '0');
    signal enc_pulse    : std_logic := '0';
    signal timer_1s     : integer range 0 to 49_999_999 := 0;
    signal pulse_count  : integer range 0 to 999 := 0;
    signal measured_rps : integer range 0 to 999 := 0;

    ----------------------------------------------------------------------------
    -- Señales del filtro (ADC -> FIR -> DAC)
    ----------------------------------------------------------------------------
    signal sample_cnt    : integer range 0 to FS_DIVIDER := 0;
    signal sample_tick   : std_logic := '0';
    signal adc_sync      : std_logic_vector(7 downto 0) := (others => '0');
    signal adc_reg       : std_logic_vector(7 downto 0) := (others => '0');
    signal filt_in       : std_logic_vector(7 downto 0) := (others => '0');
    signal filt_out      : std_logic_vector(26 downto 0);
    signal filt_scaled   : signed(8 downto 0);
    signal dac_byte_s    : std_logic_vector(7 downto 0) := (others => '0');
    signal filtered_speed : integer range 0 to FILTER_SCALE_MAX := 0;

    ----------------------------------------------------------------------------
    -- Señales displays
    ----------------------------------------------------------------------------
    signal disp_centenas : integer range 0 to 9 := 0;
    signal disp_decenas  : integer range 0 to 9 := 0;
    signal disp_unidades : integer range 0 to 9 := 0;

    signal med_millares  : integer range 0 to 9 := 0;
    signal med_centenas  : integer range 0 to 9 := 0;
    signal med_decenas   : integer range 0 to 9 := 0;
    signal med_unidades  : integer range 0 to 9 := 0;

    ----------------------------------------------------------------------------
    -- Funciones de decodificación a 7 segmentos
    ----------------------------------------------------------------------------
    function bcd_to_7seg_anode(digit : integer) return std_logic_vector is
    begin
        case digit is
            when 0 => return "0000001";
            when 1 => return "1001111";
            when 2 => return "0010010";
            when 3 => return "0000110";
            when 4 => return "1001100";
            when 5 => return "0100100";
            when 6 => return "0100000";
            when 7 => return "0001111";
            when 8 => return "0000000";
            when 9 => return "0000100";
            when others => return "1111111";
        end case;
    end function;

    function bcd_to_7seg_cathode(digit : integer) return std_logic_vector is
    begin
        case digit is
            when 0 => return "1111110";
            when 1 => return "0110000";
            when 2 => return "1101101";
            when 3 => return "1111001";
            when 4 => return "0110011";
            when 5 => return "1011011";
            when 6 => return "1011111";
            when 7 => return "1110000";
            when 8 => return "1111111";
            when 9 => return "1111011";
            when others => return "0000000";
        end case;
    end function;

begin

    ----------------------------------------------------------------------------
    -- Divisor de reloj: 50 MHz a ~260.4 kHz (tick del PWM)
    ----------------------------------------------------------------------------
    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            div_cnt  <= 0;
            tick_pwm <= '0';
        elsif rising_edge(clk_50MHz) then
            if div_cnt = 191 then
                div_cnt  <= 0;
                tick_pwm <= '1';
            else
                div_cnt  <= div_cnt + 1;
                tick_pwm <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Contador del PWM módulo 260 (0 a 260) -> PWM ~1 kHz
    ----------------------------------------------------------------------------
    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            cnt_mod260 <= 0;
        elsif rising_edge(clk_50MHz) then
            if tick_pwm = '1' then
                if cnt_mod260 = 260 then
                    cnt_mod260 <= 0;
                else
                    cnt_mod260 <= cnt_mod260 + 1;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Sincronización de las señales PS/2
    ----------------------------------------------------------------------------
    process(clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            ps2_clk_sync  <= ps2_clk_sync(1 downto 0) & ps2_clk;
            ps2_data_sync <= ps2_data_sync(0) & ps2_data;
        end if;
    end process;

    ps2_fall_edge <= '1' when (ps2_clk_sync(2 downto 1) = "10") else '0';

    ----------------------------------------------------------------------------
    -- Receptor PS/2: captura 11 bits (start, D0..D7, paridad, stop)
    ----------------------------------------------------------------------------
    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            bit_cnt       <= 0;
            ps2_shift_reg <= (others => '1');
            rx_done       <= '0';
        elsif rising_edge(clk_50MHz) then
            rx_done <= '0';
            if ps2_fall_edge = '1' then
                ps2_shift_reg <= ps2_data_sync(1) & ps2_shift_reg(10 downto 1);
                if bit_cnt = 10 then
                    bit_cnt <= 0;
                    rx_done <= '1';
                else
                    bit_cnt <= bit_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    scancode <= ps2_shift_reg(8 downto 1);

    ----------------------------------------------------------------------------
    -- Máquina de estados PS/2: captura hasta 3 dígitos y confirma con ENTER
    -- Correcciones incluidas:
    --   * Se limpian los dígitos al confirmar con ENTER (evita valores viejos)
    --   * Se ignoran las repeticiones typematic (tecla mantenida presionada)
    ----------------------------------------------------------------------------
    process(clk_50MHz, rst)
        variable digit_val : integer range 0 to 9;
        variable valid_key : boolean;
        variable temp_calc : integer;
    begin
        if rst = '1' then
            state        <= WAIT_DIGIT1;
            is_break     <= '0';
            digit1       <= 0;
            digit2       <= 0;
            digit3       <= 0;
            ref_val      <= 0;
            last_make    <= (others => '0');
            make_pending <= '0';
        elsif rising_edge(clk_50MHz) then
            if rx_done = '1' then
                if scancode = x"F0" then
                    -- Código de break: la tecla se soltó
                    is_break     <= '1';
                    make_pending <= '0';
                elsif is_break = '1' then
                    -- Código make que acompaña al break: ignorar
                    is_break <= '0';
                elsif (scancode = last_make) and (make_pending = '1') then
                    -- Repetición typematic (tecla mantenida): ignorar
                    null;
                else
                    -- Código make válido
                    last_make    <= scancode;
                    make_pending <= '1';

                    if scancode = x"5A" then
                        -- Tecla ENTER: calcular y guardar la referencia
                        case state is
                            when WAIT_DIGIT2 =>
                                temp_calc := digit1;
                            when WAIT_DIGIT3 =>
                                temp_calc := (digit1 * 10) + digit2;
                            when WAIT_ENTER | WAIT_DIGIT1 =>
                                temp_calc := (digit1 * 100) + (digit2 * 10) + digit3;
                        end case;

                        if temp_calc > 260 then
                            ref_val <= 260;
                        else
                            ref_val <= temp_calc;
                        end if;

                        -- Limpiar dígitos para una nueva captura
                        digit1 <= 0;
                        digit2 <= 0;
                        digit3 <= 0;
                        state  <= WAIT_DIGIT1;
                    else
                        -- Decodificar tecla numérica
                        valid_key := true;
                        case scancode is
                            when x"45" => digit_val := 0;
                            when x"16" => digit_val := 1;
                            when x"1E" => digit_val := 2;
                            when x"26" => digit_val := 3;
                            when x"25" => digit_val := 4;
                            when x"2E" => digit_val := 5;
                            when x"36" => digit_val := 6;
                            when x"3D" => digit_val := 7;
                            when x"3E" => digit_val := 8;
                            when x"46" => digit_val := 9;
                            when others => valid_key := false;
                        end case;

                        if valid_key then
                            case state is
                                when WAIT_DIGIT1 =>
                                    digit1 <= digit_val;
                                    digit2 <= 0;
                                    digit3 <= 0;
                                    state  <= WAIT_DIGIT2;
                                when WAIT_DIGIT2 =>
                                    digit2 <= digit_val;
                                    state  <= WAIT_DIGIT3;
                                when WAIT_DIGIT3 =>
                                    digit3 <= digit_val;
                                    state  <= WAIT_ENTER;
                                when WAIT_ENTER =>
                                    null;   -- ya hay 3 dígitos: espere ENTER
                            end case;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Generador PWM
    ----------------------------------------------------------------------------
    pwm_duty <= ref_val;

    process(pwm_duty, cnt_mod260)
    begin
        if cnt_mod260 < pwm_duty then
            pwm_out <= '1';
        else
            pwm_out <= '0';
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Sincronización y contador del Encoder (RPS en 1 segundo)
    ----------------------------------------------------------------------------
    process(clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            enc_sync <= enc_sync(1 downto 0) & encoder_in;
        end if;
    end process;

    enc_pulse <= '1' when (enc_sync(2 downto 1) = "01") else '0';

    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            timer_1s     <= 0;
            pulse_count  <= 0;
            measured_rps <= 0;
        elsif rising_edge(clk_50MHz) then
            if enc_pulse = '1' then
                pulse_count <= pulse_count + 1;
            end if;

            if timer_1s = 49_999_999 then
                timer_1s     <= 0;
                measured_rps <= pulse_count;
                pulse_count  <= 0;
            else
                timer_1s <= timer_1s + 1;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Generador del tick de muestreo del filtro: Fs = 20 kHz
    -- 50 MHz / 2500 = 20 kHz exactos
    ----------------------------------------------------------------------------
    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            sample_cnt  <= 0;
            sample_tick <= '0';
        elsif rising_edge(clk_50MHz) then
            if sample_cnt = FS_DIVIDER then
                sample_cnt  <= 0;
                sample_tick <= '1';
            else
                sample_cnt  <= sample_cnt + 1;
                sample_tick <= '0';
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- Entrada ADC: doble sincronización + registro en cada tick de muestreo
    ----------------------------------------------------------------------------
    process(clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            adc_sync <= adc_in;
        end if;
    end process;

    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            adc_reg <= (others => '0');
        elsif rising_edge(clk_50MHz) then
            if sample_tick = '1' then
                adc_reg <= adc_sync;
            end if;
        end if;
    end process;

    -- Centrar la muestra: el ADC entrega 0..255 y el filtro espera
    -- valores con signo (-128..127). Restar 128 centra la señal en cero.
    filt_in <= std_logic_vector(unsigned(adc_reg) - 128);

    ----------------------------------------------------------------------------
    -- Instancia del filtro FIR generado por MATLAB (21 coeficientes)
    -- Avanza solo cuando sample_tick = '1' (Fs = 20 kHz)
    ----------------------------------------------------------------------------
    u_filtro : filtropb
        port map (
            clk         => clk_50MHz,
            clk_enable  => sample_tick,
            reset       => rst,
            filter_in   => filt_in,
            filter_out  => filt_out
        );

    ----------------------------------------------------------------------------
    -- Escalamiento de salida: sfix27_En33 -> byte sin signo 0..255
    --   filter_out(26 downto 18) = valor / 2^18  (rango aprox. -129..128)
    --   + 128 con saturación a 0 y 255
    ----------------------------------------------------------------------------
    filt_scaled <= signed(filt_out(26 downto 18));

    process(clk_50MHz, rst)
    begin
        if rst = '1' then
            dac_byte_s <= (others => '0');
        elsif rising_edge(clk_50MHz) then
            if sample_tick = '1' then
                if filt_scaled < -128 then
                    dac_byte_s <= (others => '0');      -- saturación inferior
                elsif filt_scaled > 127 then
                    dac_byte_s <= (others => '1');      -- saturación superior
                else
                    dac_byte_s <= std_logic_vector(to_unsigned(to_integer(filt_scaled) + 128, 8));
                end if;
            end if;
        end if;
    end process;

    dac_out <= dac_byte_s;

    -- Valor filtrado para el display de medición (0..260, misma escala que la referencia)
    filtered_speed <= (to_integer(unsigned(dac_byte_s)) * FILTER_SCALE_MAX) / 255;

    ----------------------------------------------------------------------------
    -- Displays de usuario (referencia) - ánodo común, activo en '0'
    ----------------------------------------------------------------------------
    seg_millares <= "1111111";          -- primer display apagado (máx 260)

    disp_centenas <= ref_val / 100;
    disp_decenas  <= (ref_val / 10) rem 10;
    disp_unidades <= ref_val rem 10;

    seg_centenas <= bcd_to_7seg_anode(disp_centenas);
    seg_decenas  <= bcd_to_7seg_anode(disp_decenas);
    seg_unidades <= bcd_to_7seg_anode(disp_unidades);

    ----------------------------------------------------------------------------
    -- Displays de medición - cátodo común, activo en '1'
    -- Fuente seleccionable: valor filtrado (examen) o RPS del encoder
    ----------------------------------------------------------------------------
    process(measured_rps, filtered_speed)
    begin
        if MEASURE_SOURCE_FILTERED then
            med_millares <= 0;
            med_centenas <= filtered_speed / 100;
            med_decenas  <= (filtered_speed / 10) rem 10;
            med_unidades <= filtered_speed rem 10;
        else
            med_millares <= measured_rps / 1000;
            med_centenas <= (measured_rps / 100) rem 10;
            med_decenas  <= (measured_rps / 10) rem 10;
            med_unidades <= measured_rps rem 10;
        end if;
    end process;

    ext_seg_millares <= bcd_to_7seg_cathode(med_millares);
    ext_seg_centenas <= bcd_to_7seg_cathode(med_centenas);
    ext_seg_decenas  <= bcd_to_7seg_cathode(med_decenas);
    ext_seg_unidades <= bcd_to_7seg_cathode(med_unidades);

end Behavioral;
