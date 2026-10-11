library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pwm_ps2_top is
    Port (
        clk_50MHz        : in  STD_LOGIC;
        rst              : in  STD_LOGIC;
        -- Entrada Teclado PS2
        ps2_clk          : in  STD_LOGIC;
        ps2_data         : in  STD_LOGIC;
        -- Entrada Encoder (1 ranura = 1 pulso por revolución)
        encoder_in       : in  STD_LOGIC;
        -- Salida PWM
        pwm_out          : out STD_LOGIC;
        -- Displays FPGA Internos (Referencia solicitada / Activo en '0')
        seg_millares     : out STD_LOGIC_VECTOR(6 downto 0); -- PRIMER DISPLAY (APAGADO)
        seg_centenas     : out STD_LOGIC_VECTOR(6 downto 0);
        seg_decenas      : out STD_LOGIC_VECTOR(6 downto 0);
        seg_unidades     : out STD_LOGIC_VECTOR(6 downto 0);
        -- Displays Externos (RPS Medidas / Cátodo Común - Activo en '1')
        ext_seg_centenas : out STD_LOGIC_VECTOR(6 downto 0);
        ext_seg_decenas  : out STD_LOGIC_VECTOR(6 downto 0);
        ext_seg_unidades : out STD_LOGIC_VECTOR(6 downto 0)
    );
end pwm_ps2_top;

architecture Behavioral of pwm_ps2_top is

    -- Divisor de frecuencia ajustado (50 MHz / 192 = ~260.4 kHz)
    -- Para que 261 pasos (0 a 260) generen una frecuencia PWM de ~1 kHz
    signal div_cnt   : integer range 0 to 191 := 0;
    signal tick_pwm  : std_logic := '0';

    -- Contador del PWM modificado a módulo 260 (0 a 260)
    signal cnt_mod260 : integer range 0 to 260 := 0;

    -- Interfaz PS2
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

    -- Control de Referencia actualizado a límite 260
    signal ref_val  : integer range 0 to 260 := 0;
    signal pwm_duty : integer range 0 to 260 := 0;

    -- Medición Encoder (RPS/RPM reales)
    signal enc_sync     : std_logic_vector(2 downto 0) := (others => '0');
    signal enc_pulse    : std_logic := '0';
    signal timer_1s     : integer range 0 to 49_999_999 := 0;
    signal pulse_count  : integer range 0 to 999 := 0;
    signal measured_rps : integer range 0 to 999 := 0;

    -- Descomposición para Displays
    signal disp_centenas : integer range 0 to 9 := 0;
    signal disp_decenas  : integer range 0 to 9 := 0;
    signal disp_unidades : integer range 0 to 9 := 0;

    signal rps_centenas  : integer range 0 to 9 := 0;
    signal rps_decenas   : integer range 0 to 9 := 0;
    signal rps_unidades  : integer range 0 to 9 := 0;

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

    -- Divisor de reloj: 50 MHz a ~260.4 kHz
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

    -- Contador del PWM de 0 a 260
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

    -- Sincronización PS2
    process(clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            ps2_clk_sync  <= ps2_clk_sync(1 downto 0) & ps2_clk;
            ps2_data_sync <= ps2_data_sync(0) & ps2_data;
        end if;
    end process;

    ps2_fall_edge <= '1' when (ps2_clk_sync(2 downto 1) = "10") else '0';

    -- Recepción PS2
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

    -- Máquina de estados para capturar hasta 260
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
                        case state is
                            when WAIT_DIGIT2 =>
                                temp_calc := digit1;
                            when WAIT_DIGIT3 =>
                                temp_calc := (digit1 * 10) + digit2;
                            when WAIT_ENTER | WAIT_DIGIT1 =>
                                temp_calc := (digit1 * 100) + (digit2 * 10) + digit3;
                        end case;

                        -- Límite de entrada actualizado a 260
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
                                    null;
                            end case;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Asignación directa
    process(ref_val)
    begin
        pwm_duty <= ref_val; 
    end process;

    -- Generador PWM comparando con el nuevo límite (260)
    process(pwm_duty, cnt_mod260)
    begin
        if cnt_mod260 < pwm_duty then
            pwm_out <= '1';
        else
            pwm_out <= '0';
        end if;
    end process;

    -- Sincronización de Encoder
    process(clk_50MHz)
    begin
        if rising_edge(clk_50MHz) then
            enc_sync <= enc_sync(1 downto 0) & encoder_in;
        end if;
    end process;

    enc_pulse <= '1' when (enc_sync(2 downto 1) = "01") else '0';

    -- Contador de RPM/RPS
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

    -- Apagar el primer display (HEX3)
    seg_millares <= "1111111";

    -- Desglose para displays (Referencia)
    disp_centenas <= ref_val / 100;
    disp_decenas  <= (ref_val / 10) rem 10;
    disp_unidades <= ref_val rem 10;

    seg_centenas <= bcd_to_7seg_anode(disp_centenas);
    seg_decenas  <= bcd_to_7seg_anode(disp_decenas);
    seg_unidades <= bcd_to_7seg_anode(disp_unidades);

    -- Desglose para displays (Velocidad real)
    rps_centenas <= measured_rps / 100;
    rps_decenas  <= (measured_rps / 10) rem 10;
    rps_unidades <= measured_rps rem 10;

    ext_seg_centenas <= bcd_to_7seg_cathode(rps_centenas);
    ext_seg_decenas  <= bcd_to_7seg_cathode(rps_decenas);
    ext_seg_unidades <= bcd_to_7seg_cathode(rps_unidades);

end Behavioral;