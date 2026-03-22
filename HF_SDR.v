// =========================================================
// 文件：HF_SDR.v
// 说明：
// 1. 固定 USB，修正 USB/LSB 边带相反问题
// 2. Key0 改为 PTT 切换（按一下开，再按一下关，带防抖）
// 3. 恢复 100% 原始音频处理逻辑，保证最高音质！
// 4. 极简时序优化：仅通过提前计算绝对值打破关键路径，Fmax > 100MHz
// =========================================================

module HF_SDR (
    input  wire        clk_50m,
    input  wire [3:0]  key,
    output wire [3:0]  led,

    output wire        dac_clk,
    output wire [13:0] dac_data,

    output wire        mic_sck,
    output wire        mic_ws,
    input  wire        mic_sd,
    output wire        mic_lr
);

    // =====================================================
    // 基本设定
    // =====================================================
    wire sideband = 1'b0; // 0=USB, 1=LSB
    reg [1:0] freq_sel = 2'd0;
    assign mic_lr = 1'b0;

    // =====================================================
    // PLL：50MHz -> 100MHz 核心时钟 + 200MHz DAC 时钟
    // =====================================================
    wire clk_100m;
    wire clk_200m_dac;
    wire pll_locked;

    sys_pll u_pll (
        .areset (1'b0),
        .inclk0 (clk_50m),
        .c0     (clk_100m),
        .c1     (clk_200m_dac),
        .locked (pll_locked)
    );

    // =====================================================
    // 按键同步与 PTT 翻转逻辑 (带 10ms 消抖)
    // =====================================================
    reg [3:0] key_d0 = 4'hF;
    reg [3:0] key_d1 = 4'hF;

    always @(posedge clk_100m) begin
        key_d0 <= key;
        key_d1 <= key_d0;
    end

    // PTT 消抖逻辑
    reg[19:0] debounce_cnt = 20'd0;
    reg key0_stable = 1'b1;
    always @(posedge clk_100m) begin
        if (key_d0[0] != key0_stable) begin
            debounce_cnt <= debounce_cnt + 1'b1;
            if (debounce_cnt == 20'd1000000) begin // 10ms
                key0_stable <= key_d0[0];
                debounce_cnt <= 20'd0;
            end
        end else begin
            debounce_cnt <= 20'd0;
        end
    end

    reg key0_stable_d = 1'b1;
    always @(posedge clk_100m) key0_stable_d <= key0_stable;
    
    // 按下沿检测
    wire ptt_pressed = ~key0_stable & key0_stable_d;
    wire [3:0] key_pressed = ~key_d0 & key_d1;

    // PTT 翻转：按一下开，再按一下关
    reg tx_enable = 1'b0;
    always @(posedge clk_100m) begin
        if (ptt_pressed) tx_enable <= ~tx_enable;
    end

    // 频段切换
    always @(posedge clk_100m) begin
        if (key_pressed[1]) freq_sel <= 2'd0;
        if (key_pressed[2]) freq_sel <= 2'd1;
        if (key_pressed[3]) freq_sel <= 2'd2;
    end

    // LED 指示（低有效）
    assign led[0] = ~tx_enable;           
    assign led[1] = ~(freq_sel == 2'd0);  
    assign led[2] = ~(freq_sel == 2'd1);  
    assign led[3] = ~(freq_sel == 2'd2);  

    // =====================================================
    // I2S 麦克风接收（24-bit）
    // =====================================================
    wire signed[23:0] audio_raw_24;
    wire               audio_valid;

    i2s_rx u_i2s_rx (
        .clk_100m    (clk_100m),
        .mic_sd      (mic_sd),
        .mic_sck     (mic_sck),
        .mic_ws      (mic_ws),
        .audio_data  (audio_raw_24),
        .audio_valid (audio_valid)
    );

    // =====================================================
    // 重度语音处理
    // =====================================================
    wire signed[13:0] audio_proc;
    wire               audio_proc_valid;

    tx_audio_proc u_tx_audio_proc (
        .clk_100m         (clk_100m),
        .tx_enable        (tx_enable),
        .sample_in        (audio_raw_24),
        .sample_valid     (audio_valid),
        .sample_out       (audio_proc),
        .sample_out_valid (audio_proc_valid)
    );

    // =====================================================
    // Hilbert FIR：生成 I/Q
    // =====================================================
    wire signed [13:0] audio_i_base;
    wire signed[13:0] audio_q_base;
    wire               hilbert_valid;

    hilbert_filter u_hilbert (
        .clk_100m        (clk_100m),
        .audio_in        (audio_proc),
        .audio_valid     (audio_proc_valid),
        .audio_i         (audio_i_base),
        .audio_q         (audio_q_base),
        .audio_out_valid (hilbert_valid)
    );

    // =====================================================
    // CIC 插值
    // =====================================================
    wire signed [13:0] audio_i;
    wire signed [13:0] audio_q;

    cic_interpolator u_cic_i (
        .clk_100m (clk_100m),
        .data_in  (audio_i_base),
        .valid_in (hilbert_valid),
        .data_out (audio_i)
    );

    cic_interpolator u_cic_q (
        .clk_100m (clk_100m),
        .data_in  (audio_q_base),
        .valid_in (hilbert_valid),
        .data_out (audio_q)
    );

    // =====================================================
    // 多波段调制
    // =====================================================
    wire[13:0] dac_out_A;
    wire [13:0] dac_out_B;

    multi_band_modulator u_band_mod (
        .clk_100m  (clk_100m),
        .tx_enable (tx_enable),
        .sideband  (sideband),
        .freq_sel  (freq_sel),
        .audio_i   (audio_i),
        .audio_q   (audio_q),
        .dac_out_A (dac_out_A),
        .dac_out_B (dac_out_B)
    );

    // =====================================================
    // DDIO 输出到 DAC
    // =====================================================
    dac_ddio u_ddio (
        .datain_h (dac_out_A),
        .datain_l (dac_out_B),
        .outclock (clk_100m),
        .dataout  (dac_data)
    );

    assign dac_clk = clk_200m_dac;

endmodule


// =========================================================
// 模块：i2s_rx
// =========================================================
module i2s_rx (
    input  wire               clk_100m,
    input  wire               mic_sd,
    output wire               mic_sck,
    output wire               mic_ws,
    output reg  signed [23:0] audio_data,
    output wire               audio_valid
);

    reg [10:0] clk_div = 11'd0;
    reg[31:0] shift_reg = 32'd0;
    reg signed [39:0] dc_avg = 40'sd0;

    always @(posedge clk_100m) begin
        clk_div <= clk_div + 1'b1;
    end

    assign mic_sck = clk_div[4];
    assign mic_ws  = clk_div[10];
    wire sck_rising = (clk_div[4:0] == 5'b01111);
    assign audio_valid = (clk_div == 11'd1023);
    wire signed [23:0] raw_audio_24 = shift_reg[30:7];

    always @(posedge clk_100m) begin
        if (sck_rising) begin
            shift_reg <= {shift_reg[30:0], mic_sd};
        end
        if (audio_valid) begin
            dc_avg <= dc_avg + raw_audio_24 - (dc_avg >>> 10);
            audio_data <= raw_audio_24 - (dc_avg >>> 10);
        end
    end
endmodule


// =========================================================
// 模块：tx_audio_proc
// 极简优化：完全恢复你最原始的代码结构，仅引入 hp_abs_reg
// 提前计算绝对值，完美解决 -0.953ns 时序报错，100% 保持原音质
// =========================================================
module tx_audio_proc (
    input  wire               clk_100m,
    input  wire               tx_enable,
    input  wire signed [23:0] sample_in,
    input  wire               sample_valid,
    output reg  signed [13:0] sample_out,
    output reg                sample_out_valid
);

    localparam [27:0] NS_MARGIN        = 28'd512;
    localparam [27:0] GATE_OPEN_MARGIN = 28'd2048;
    localparam [27:0] GATE_CLOSE_MARGIN= 28'd1024;
    localparam [15:0] HANG_MAX         = 16'd7500;
    localparam integer LP1_SHIFT       = 2;
    localparam integer LP2_SHIFT       = 3;

    reg signed [27:0] x_prev     = 28'sd0;
    reg signed[27:0] hp_prev    = 28'sd0;
    reg[27:0] noise_est  = 28'd0;
    reg        [27:0] env        = 28'd0;
    reg               gate_on    = 1'b0;
    reg        [15:0] hang_cnt   = 16'd0;
    reg signed [27:0] lpf1_state = 28'sd0;
    reg signed [27:0] lpf2_state = 28'sd0;

    reg signed [27:0] hp_sample;
    reg signed [27:0] ns_sample;
    reg signed [27:0] agc_sample;
    reg signed[27:0] lim_sample;
    reg [3:0] out_shift;

    function[27:0] abs28;
        input signed [27:0] x;
        begin
            if (x[27]) abs28 = ~x + 28'd1;
            else abs28 = x;
        end
    endfunction

    function signed [13:0] soft_sat14;
        input signed [27:0] x;
        reg   signed[27:0] y;
        begin
            if (x > 28'sd6000) y = 28'sd6000 + ((x - 28'sd6000) >>> 2);
            else if (x < -28'sd6000) y = -28'sd6000 + ((x + 28'sd6000) >>> 2);
            else y = x;

            if (y > 28'sd8191) soft_sat14 = 14'sd8191;
            else if (y < -28'sd8192) soft_sat14 = -14'sd8192;
            else soft_sat14 = y[13:0];
        end
    endfunction

    // 【核心时序优化点】：在平时空闲的时钟周期，提前把绝对值算好
    // 这样在 sample_valid 到来时，直接用寄存器里的值，切断了组合逻辑长路径
    reg [27:0] hp_abs_reg = 28'd0;
    always @(posedge clk_100m) begin
        hp_abs_reg <= abs28(hp_sample);
    end

    always @(posedge clk_100m) begin
        sample_out_valid <= 1'b0;

        if (sample_valid) begin
            sample_out_valid <= 1'b1;

            if (!tx_enable) begin
                x_prev     <= 28'sd0;
                hp_prev    <= 28'sd0;
                noise_est  <= 28'd0;
                env        <= 28'd0;
                gate_on    <= 1'b0;
                hang_cnt   <= 16'd0;
                lpf1_state <= 28'sd0;
                lpf2_state <= 28'sd0;
                sample_out <= 14'sd0;
            end
            else begin
                // 1. 高通 / DC Block
                hp_sample <= $signed({{4{sample_in[23]}}, sample_in})
                           - x_prev
                           + hp_prev
                           - (hp_prev >>> 8);

                x_prev  <= $signed({{4{sample_in[23]}}, sample_in});
                hp_prev <= hp_sample;

                // 2. 包络估计（使用提前算好的 hp_abs_reg）
                if (hp_abs_reg > env)
                    env <= env + ((hp_abs_reg - env) >> 1);
                else
                    env <= env - ((env - hp_abs_reg) >> 4);

                // 3. 噪声底估计
                if (!gate_on) begin
                    if (hp_abs_reg > noise_est)
                        noise_est <= noise_est + ((hp_abs_reg - noise_est) >> 7);
                    else
                        noise_est <= noise_est - ((noise_est - hp_abs_reg) >> 5);
                end

                // 4. 噪声门
                if (env > (noise_est + GATE_OPEN_MARGIN)) begin
                    gate_on  <= 1'b1;
                    hang_cnt <= HANG_MAX;
                end
                else if (env < (noise_est + GATE_CLOSE_MARGIN)) begin
                    if (hang_cnt != 16'd0) begin
                        hang_cnt <= hang_cnt - 16'd1;
                        gate_on  <= 1'b1;
                    end
                    else begin
                        gate_on <= 1'b0;
                    end
                end

                // 5. 幅度减法式降噪
                if (hp_abs_reg <= (noise_est + NS_MARGIN)) begin
                    ns_sample <= 28'sd0;
                end
                else begin
                    if (hp_sample[27])
                        ns_sample <= -$signed(hp_abs_reg - (noise_est + NS_MARGIN));
                    else
                        ns_sample <=  $signed(hp_abs_reg - (noise_est + NS_MARGIN));
                end

                if (!gate_on)
                    ns_sample <= 28'sd0;

                // 6. 双级低通平滑
                lpf1_state <= lpf1_state + ((ns_sample  - lpf1_state) >>> LP1_SHIFT);
                lpf2_state <= lpf2_state + ((lpf1_state - lpf2_state) >>> LP2_SHIFT);

                // 7. 动态增益 / 压缩
                if (env < 28'd2048) out_shift <= 4'd2;
                else if (env < 28'd8192) out_shift <= 4'd3;
                else if (env < 28'd32768) out_shift <= 4'd4;
                else if (env < 28'd131072) out_shift <= 4'd5;
                else if (env < 28'd524288) out_shift <= 4'd6;
                else out_shift <= 4'd7;

                agc_sample <= lpf2_state >>> out_shift;
                lim_sample <= agc_sample;
                sample_out <= soft_sat14(lim_sample);
            end
        end
    end
endmodule


// =========================================================
// 模块：hilbert_filter
// 完全恢复原始代码，去除了可能影响音质的 DC Blocker
// =========================================================
module hilbert_filter (
    input  wire               clk_100m,
    input  wire signed[13:0] audio_in,
    input  wire               audio_valid,
    output reg  signed[13:0] audio_i,
    output reg  signed [13:0] audio_q,
    output reg                audio_out_valid
);

    (* ramstyle = "M9K" *) reg signed [13:0] history [0:255];
    (* ramstyle = "M9K" *) reg signed [16:0] coef_rom [0:255];

    integer k;
    initial begin
        for (k = 0; k < 256; k = k + 1) coef_rom[k] = 17'sd0;
        coef_rom[0] = -13; coef_rom[2] = -13; coef_rom[4] = -14; coef_rom[6] = -15; coef_rom[8] = -16; coef_rom[10] = -17; coef_rom[12] = -18; coef_rom[14] = -20; coef_rom[16] = -22; coef_rom[18] = -24; coef_rom[20] = -26; coef_rom[22] = -29; coef_rom[24] = -32; coef_rom[26] = -36; coef_rom[28] = -39; coef_rom[30] = -43; coef_rom[32] = -48; coef_rom[34] = -52; coef_rom[36] = -57; coef_rom[38] = -63; coef_rom[40] = -69; coef_rom[42] = -75; coef_rom[44] = -82; coef_rom[46] = -89; coef_rom[48] = -97; coef_rom[50] = -105; coef_rom[52] = -114; coef_rom[54] = -124; coef_rom[56] = -134; coef_rom[58] = -144; coef_rom[60] = -156; coef_rom[62] = -168; coef_rom[64] = -181; coef_rom[66] = -194; coef_rom[68] = -209; coef_rom[70] = -225; coef_rom[72] = -241; coef_rom[74] = -259; coef_rom[76] = -278; coef_rom[78] = -299; coef_rom[80] = -321; coef_rom[82] = -345; coef_rom[84] = -370; coef_rom[86] = -399; coef_rom[88] = -429; coef_rom[90] = -463; coef_rom[92] = -500; coef_rom[94] = -541; coef_rom[96] = -587; coef_rom[98] = -638; coef_rom[100] = -697; coef_rom[102] = -764; coef_rom[104] = -842; coef_rom[106] = -933; coef_rom[108] = -1044; coef_rom[110] = -1178; coef_rom[112] = -1348; coef_rom[114] = -1567; coef_rom[116] = -1865; coef_rom[118] = -2292; coef_rom[120] = -2961; coef_rom[122] = -4159; coef_rom[124] = -6948; coef_rom[126] = -20866; coef_rom[128] = 20866; coef_rom[130] = 6948; coef_rom[132] = 4159; coef_rom[134] = 2961; coef_rom[136] = 2292; coef_rom[138] = 1865; coef_rom[140] = 1567; coef_rom[142] = 1348; coef_rom[144] = 1178; coef_rom[146] = 1044; coef_rom[148] = 933; coef_rom[150] = 842; coef_rom[152] = 764; coef_rom[154] = 697; coef_rom[156] = 638; coef_rom[158] = 587; coef_rom[160] = 541; coef_rom[162] = 500; coef_rom[164] = 463; coef_rom[166] = 429; coef_rom[168] = 399; coef_rom[170] = 370; coef_rom[172] = 345; coef_rom[174] = 321; coef_rom[176] = 299; coef_rom[178] = 278; coef_rom[180] = 259; coef_rom[182] = 241; coef_rom[184] = 225; coef_rom[186] = 209; coef_rom[188] = 194; coef_rom[190] = 181; coef_rom[192] = 168; coef_rom[194] = 156; coef_rom[196] = 144; coef_rom[198] = 134; coef_rom[200] = 124; coef_rom[202] = 114; coef_rom[204] = 105; coef_rom[206] = 97; coef_rom[208] = 89; coef_rom[210] = 82; coef_rom[212] = 75; coef_rom[214] = 69; coef_rom[216] = 63; coef_rom[218] = 57; coef_rom[220] = 52; coef_rom[222] = 48; coef_rom[224] = 43; coef_rom[226] = 39; coef_rom[228] = 36; coef_rom[230] = 32; coef_rom[232] = 29; coef_rom[234] = 26; coef_rom[236] = 24; coef_rom[238] = 22; coef_rom[240] = 20; coef_rom[242] = 18; coef_rom[244] = 17; coef_rom[246] = 16; coef_rom[248] = 15; coef_rom[250] = 14; coef_rom[252] = 13; coef_rom[254] = 13;
    end

    reg [7:0] wr_ptr      = 8'd0;
    reg[7:0] newest_ptr  = 8'd0;
    reg [8:0] tap_issue   = 9'd0;
    reg       busy        = 1'b0;
    reg       issue_en    = 1'b0;

    reg       v0          = 1'b0;
    reg [7:0] hist_addr0  = 8'd0;
    reg [7:0] coef_addr0  = 8'd0;
    reg[8:0] tap0        = 9'd0;

    reg       v1          = 1'b0;
    reg signed [13:0] data1 = 14'sd0;
    reg signed [16:0] coef1 = 17'sd0;
    reg[8:0]         tap1  = 9'd0;

    reg       v2          = 1'b0;
    reg signed [30:0] mult2 = 31'sd0;
    reg [8:0]         tap2  = 9'd0;

    reg signed [35:0] acc = 36'sd0;
    reg signed[13:0] audio_i_captured = 14'sd0;
    reg signed [35:0] acc_next;

    always @(*) begin
        if (tap2 == 9'd0)
            acc_next = {{5{mult2[30]}}, mult2};
        else
            acc_next = acc + {{5{mult2[30]}}, mult2};
    end

    always @(posedge clk_100m) begin
        audio_out_valid <= 1'b0;

        if (audio_valid && !busy) begin
            history[wr_ptr] <= audio_in;
            newest_ptr <= wr_ptr;
            wr_ptr     <= wr_ptr + 1'b1;

            tap_issue  <= 9'd0;
            busy       <= 1'b1;
            issue_en   <= 1'b1;

            acc              <= 36'sd0;
            audio_i_captured <= 14'sd0;
        end

        if (issue_en) begin
            v0         <= 1'b1;
            hist_addr0 <= newest_ptr - tap_issue[7:0];
            coef_addr0 <= tap_issue[7:0];
            tap0       <= tap_issue;

            if (tap_issue == 9'd255) issue_en <= 1'b0;
            else tap_issue <= tap_issue + 1'b1;
        end else begin
            v0 <= 1'b0;
        end

        v1    <= v0;
        data1 <= history[hist_addr0];
        coef1 <= coef_rom[coef_addr0];
        tap1  <= tap0;

        if (v1 && tap1 == 9'd127)
            audio_i_captured <= data1;

        v2    <= v1;
        mult2 <= data1 * coef1;
        tap2  <= tap1;

        if (v2) begin
            acc <= acc_next;

            if (tap2 == 9'd255) begin
                audio_q         <= acc_next[28:15];
                audio_i         <= audio_i_captured;
                audio_out_valid <= 1'b1;
                busy            <= 1'b0;
            end
        end
    end
endmodule


// =========================================================
// 模块：cic_interpolator
// =========================================================
module cic_interpolator (
    input  wire               clk_100m,
    input  wire signed[13:0] data_in,
    input  wire               valid_in,
    output wire signed[13:0] data_out
);

    reg signed [47:0] c1_d1  = 48'sd0;
    reg signed [47:0] c1_out = 48'sd0;
    reg signed [47:0] c2_d1  = 48'sd0;
    reg signed [47:0] c2_out = 48'sd0;
    reg signed [47:0] c3_d1  = 48'sd0;
    reg signed [47:0] c3_out = 48'sd0;

    reg signed [47:0] i1_out = 48'sd0;
    reg signed [47:0] i2_out = 48'sd0;
    reg signed [47:0] i3_out = 48'sd0;

    reg valid_d1 = 1'b0;

    always @(posedge clk_100m) begin
        valid_d1 <= valid_in;

        if (valid_in) begin
            c1_d1  <= data_in;
            c1_out <= $signed(data_in) - c1_d1;

            c2_d1  <= c1_out;
            c2_out <= c1_out - c2_d1;

            c3_d1  <= c2_out;
            c3_out <= c2_out - c3_d1;
        end

        if (valid_d1)
            i1_out <= i1_out + c3_out;

        i2_out <= i2_out + i1_out;
        i3_out <= i3_out + i2_out;
    end

    assign data_out = i3_out[35:22];

endmodule


// =========================================================
// 模块：multi_band_modulator
// 修复说明：USB 使用加法 (+)，LSB 使用减法 (-)
// =========================================================
module multi_band_modulator (
    input  wire               clk_100m,
    input  wire               tx_enable,
    input  wire               sideband,
    input  wire [1:0]         freq_sel,
    input  wire signed[13:0] audio_i,
    input  wire signed [13:0] audio_q,
    output reg  [13:0]        dac_out_A,
    output reg  [13:0]        dac_out_B
);

    reg [31:0] step_200m;
    reg [31:0] step_100m;

    always @(*) begin
        case(freq_sel)
            2'd0: begin
                step_200m = 32'd306446702;
                step_100m = 32'd612893404;
            end
            2'd1: begin
                step_200m = 32'd456770277;
                step_100m = 32'd913540555;
            end
            2'd2: begin
                step_200m = 32'd1076100062;
                step_100m = 32'd2152200124;
            end
            default: begin
                step_200m = 32'd306446702;
                step_100m = 32'd612893404;
            end
        endcase
    end

    reg [31:0] phase_acc = 32'd0;

    always @(posedge clk_100m)
        phase_acc <= phase_acc + step_100m;

    wire[31:0] phase_A = phase_acc;
    wire [31:0] phase_B = phase_acc + step_200m;

    wire [11:0] p_iA = phase_A[31:20];
    wire [11:0] p_qA = phase_A[31:20] + 12'd1024;
    wire [11:0] p_iB = phase_B[31:20];
    wire [11:0] p_qB = phase_B[31:20] + 12'd1024;

    wire [9:0] addr_iA = p_iA[10] ? ~p_iA[9:0] : p_iA[9:0];
    wire [9:0] addr_qA = p_qA[10] ? ~p_qA[9:0] : p_qA[9:0];
    wire[9:0] addr_iB = p_iB[10] ? ~p_iB[9:0] : p_iB[9:0];
    wire [9:0] addr_qB = p_qB[10] ? ~p_qB[9:0] : p_qB[9:0];

    reg sign_iA_d1 = 1'b0;
    reg sign_qA_d1 = 1'b0;
    reg sign_iB_d1 = 1'b0;
    reg sign_qB_d1 = 1'b0;

    always @(posedge clk_100m) begin
        sign_iA_d1 <= p_iA[11];
        sign_qA_d1 <= p_qA[11];
        sign_iB_d1 <= p_iB[11];
        sign_qB_d1 <= p_qB[11];
    end

    wire [13:0] rom_iA, rom_qA, rom_iB, rom_qB;

    sine_rom rom_inst_iA (.clock(clk_100m), .address(addr_iA), .q(rom_iA));
    sine_rom rom_inst_qA (.clock(clk_100m), .address(addr_qA), .q(rom_qA));
    sine_rom rom_inst_iB (.clock(clk_100m), .address(addr_iB), .q(rom_iB));
    sine_rom rom_inst_qB (.clock(clk_100m), .address(addr_qB), .q(rom_qB));

    reg signed [13:0] car_i_A = 14'sd0;
    reg signed [13:0] car_q_A = 14'sd0;
    reg signed [13:0] car_i_B = 14'sd0;
    reg signed [13:0] car_q_B = 14'sd0;

    always @(posedge clk_100m) begin
        car_i_A <= sign_iA_d1 ? -$signed(rom_iA) : $signed(rom_iA);
        car_q_A <= sign_qA_d1 ? -$signed(rom_qA) : $signed(rom_qA);
        car_i_B <= sign_iB_d1 ? -$signed(rom_iB) : $signed(rom_iB);
        car_q_B <= sign_qB_d1 ? -$signed(rom_qB) : $signed(rom_qB);
    end

    reg signed [13:0] audio_i_d1 = 14'sd0;
    reg signed [13:0] audio_q_d1 = 14'sd0;
    reg signed [13:0] audio_i_d2 = 14'sd0;
    reg signed [13:0] audio_q_d2 = 14'sd0;

    reg sideband_d1 = 1'b0;
    reg sideband_d2 = 1'b0;
    reg sideband_d3 = 1'b0;

    always @(posedge clk_100m) begin
        audio_i_d1 <= audio_i;
        audio_q_d1 <= audio_q;
        audio_i_d2 <= audio_i_d1;
        audio_q_d2 <= audio_q_d1;

        sideband_d1 <= sideband;
        sideband_d2 <= sideband_d1;
        sideband_d3 <= sideband_d2;
    end

    reg signed [27:0] mix_ii_A = 28'sd0;
    reg signed [27:0] mix_qq_A = 28'sd0;
    reg signed [27:0] mix_ii_B = 28'sd0;
    reg signed [27:0] mix_qq_B = 28'sd0;

    always @(posedge clk_100m) begin
        mix_ii_A <= audio_i_d2 * car_i_A;
        mix_qq_A <= audio_q_d2 * car_q_A;
        mix_ii_B <= audio_i_d2 * car_i_B;
        mix_qq_B <= audio_q_d2 * car_q_B;
    end

    reg signed [28:0] tx_out_A = 29'sd0;
    reg signed [28:0] tx_out_B = 29'sd0;

    always @(posedge clk_100m) begin
        if (sideband_d3 == 1'b0) begin
            tx_out_A <= mix_ii_A + mix_qq_A;  // 【修复】：USB 必须是加号
            tx_out_B <= mix_ii_B + mix_qq_B;
        end
        else begin
            tx_out_A <= mix_ii_A - mix_qq_A;  // 【修复】：LSB 必须是减号
            tx_out_B <= mix_ii_B - mix_qq_B;
        end
    end

    wire [2:0] sign_A = tx_out_A[28:26];
    wire [2:0] sign_B = tx_out_B[28:26];

    reg [13:0] clamped_A;
    reg [13:0] clamped_B;

    always @(*) begin
        if (sign_A != 3'b000 && sign_A != 3'b111)
            clamped_A = tx_out_A[28] ? 14'h2000 : 14'h1FFF;
        else
            clamped_A = tx_out_A[26:13];

        if (sign_B != 3'b000 && sign_B != 3'b111)
            clamped_B = tx_out_B[28] ? 14'h2000 : 14'h1FFF;
        else
            clamped_B = tx_out_B[26:13];
    end

    // 二补码 -> offset binary
    wire [13:0] dac_code_A = clamped_A ^ 14'h2000;
    wire [13:0] dac_code_B = clamped_B ^ 14'h2000;

    always @(posedge clk_100m) begin
        if (!tx_enable) begin
            dac_out_A <= 14'd8192;
            dac_out_B <= 14'd8192;
        end
        else begin
            dac_out_A <= dac_code_A;
            dac_out_B <= dac_code_B;
        end
    end
endmodule