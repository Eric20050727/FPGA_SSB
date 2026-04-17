# FPGA_SSB

一个面向自我探索的 FPGA + RF 小项目。  
A self-exploration FPGA + RF project.

使用 **Cyclone IV E EP4CE10（4CE10）** + **AD9744（14-bit 并行 DAC）** + **I2S 数字麦克风**，实现简化的语音 SSB（单边带）发射数字链路。  
Built with **Cyclone IV E EP4CE10 (4CE10)** + **AD9744 (14-bit parallel DAC)** + **I2S digital microphone** to implement a simplified voice SSB transmit digital chain.

## 项目定位 | Project Positioning

- 这是学习/实验工程，不是产品化项目。  
  This is a learning/experimental project, not a product.
- 目标是把“音频采集 → I/Q 生成 → SSB 调制 → DAC 输出”在 FPGA 上跑通。  
  The goal is to make “audio capture → I/Q generation → SSB modulation → DAC output” run on FPGA.
- 重点在“可综合、可布线、可时序收敛”的真实实现。  
  Focus is on a real implementation that can be synthesized, placed/routed, and meet timing.

## 硬件与工具 | Hardware & Toolchain

- FPGA: **EP4CE10F17C8**
- DAC: **AD9744**
- 音频输入 / Audio Input: **I2S 麦克风模块 / I2S microphone module**
- 开发环境 / Toolchain: **Quartus II 13.1**

## 信号链（简版） | Signal Chain (Simplified)

```text
I2S Microphone
  -> I2S RX / DC removal
  -> Audio pre-processing
  -> Hilbert filter (I/Q generation)
  -> CIC interpolation
  -> NCO quadrature modulation
  -> USB/LSB generation
  -> AD9744 parallel DAC output
```

## 学习收获 | What You Can Learn

- FPGA 内 I2S 采样与时序对齐 / I2S sampling and timing alignment in FPGA
- Hilbert / I-Q 在 SSB 中的作用 / Hilbert and I-Q roles in SSB
- NCO（相位累加器 + ROM）基础 / NCO basics (phase accumulator + ROM)
- 插值与定点信号链处理 / Interpolation and fixed-point signal-chain handling
- Quartus 约束与时序分析流程 / Quartus constraints and timing-analysis workflow

## 代码入口 | Code Entry Points

- `HF_SDR.v`: 顶层与主处理链 / top-level and main processing chain
- `sine_rom.v`: NCO 正弦 ROM / sine ROM for NCO
- `sys_pll.v`: PLL 相关 / PLL-related files
- `dac_ddio.vhd`: DAC DDIO 输出 / DAC DDIO output
- `HF_SDR.qsf`: 工程与引脚约束 / project config and pin assignments
- `HF_SDR.sdc`: 时钟与时序约束 / clock and timing constraints

建议阅读顺序 / Suggested reading order:  
`HF_SDR.v` top ports → `i2s_rx` → `tx_audio_proc` → `hilbert_filter` → `cic_interpolator` → `multi_band_modulator`.

## 使用提醒 | Notes & Safety

- 本项目涉及 RF 发射实验，请遵守当地无线电法规。  
  This project involves RF transmission experiments; follow local radio regulations.
- 接后级功放/天线前，请先确认滤波、频谱纯净度与功率安全。  
  Before connecting PA/antenna, verify filtering, spectral purity, and power safety.

## 后续计划（可选） | Optional Roadmap

- 补充 testbench / Add testbenches
- 整理滤波器系数说明 / Document filter coefficients
- 增加频谱与板级连接图 / Add spectrum captures and board-level connection diagrams
